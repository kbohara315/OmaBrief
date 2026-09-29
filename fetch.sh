#!/usr/bin/env bash
# Herald fetch helper: all network and XML work happens here, outside the
# long-running shell process. QML only ever reads the JSON cache this script
# writes, so raw payloads and parsing never touch shell memory.
#
#   fetch.sh STATE_DIR poll                  fetch every source in feeds.txt
#   fetch.sh STATE_DIR comments HNID         fetch an HN comment thread
#   fetch.sh STATE_DIR article URL           extract readable text of a page
#   fetch.sh STATE_DIR digest                write digest.md + notify top 5
#   fetch.sh STATE_DIR write-config JSON     validate and store config.json
#
# Dependencies (all guaranteed on Omarchy): curl, xmllint (libxml2), jq.
# Exit 0 on best-effort completion; per-source failures land in status.json.

set -u
STATE="${1:?usage: fetch.sh STATE_DIR <poll|comments|article|digest|write-config> ...}"
MODE="${2:?usage: fetch.sh STATE_DIR <poll|comments|article|digest|write-config> ...}"

HN_API="https://hacker-news.firebaseio.com/v0"
UA="herald-omarchy-plugin/0.1.0"
# Article pages fetch with browser-like headers — a plain curl UA/headers
# trips naive bot checks and gets challenge pages instead of content. Feeds
# keep the honest UA above; only page extraction disguises itself.
ARTICLE_CURL=(
  -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
  -H 'Accept-Language: en-US,en;q=0.9'
  -H 'Upgrade-Insecure-Requests: 1'
  -H 'Sec-Fetch-Dest: document'
  -H 'Sec-Fetch-Mode: navigate'
  -H 'Sec-Fetch-Site: none'
  -H 'Sec-Fetch-User: ?1'
)
MAX_BYTES=5242880
SEP="|~|"

mkdir -p "$STATE"/{cache,etags,hn,articles}

log() { printf '%s\n' "$*" >>"$STATE/fetch.log"; }
now_epoch() { date +%s; }

# sha1 of a string, portable across coreutils/busybox
sha1() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

atomic_write() { # dest ; reads stdin
  local dest="$1" tmp
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  cat >"$tmp" && mv -f "$tmp" "$dest"
}

# ---------------------------------------------------------------- config ---

read_config() {
  if [ -f "$STATE/config.json" ]; then
    REFRESH_MINUTES=$(jq -r '.refreshMinutes // 15' "$STATE/config.json" 2>/dev/null || echo 15)
    STORY_COUNT=$(jq -r '.storyCount // 30' "$STATE/config.json" 2>/dev/null || echo 30)
    MAX_PER_FEED=$(jq -r '.maxItemsPerFeed // 30' "$STATE/config.json" 2>/dev/null || echo 30)
  else
    REFRESH_MINUTES=15 STORY_COUNT=30 MAX_PER_FEED=30
  fi
  case "$REFRESH_MINUTES" in ''|*[!0-9]*) REFRESH_MINUTES=15 ;; esac
  case "$STORY_COUNT" in ''|*[!0-9]*) STORY_COUNT=30 ;; esac
  case "$MAX_PER_FEED" in ''|*[!0-9]*) MAX_PER_FEED=30 ;; esac
  [ "$REFRESH_MINUTES" -lt 2 ] && REFRESH_MINUTES=2
  [ "$STORY_COUNT" -lt 1 ] && STORY_COUNT=1
  [ "$STORY_COUNT" -gt 100 ] && STORY_COUNT=100
  [ "$MAX_PER_FEED" -lt 1 ] && MAX_PER_FEED=1
  [ "$MAX_PER_FEED" -gt 100 ] && MAX_PER_FEED=100
}

# --------------------------------------------------------------- fetchers ---

# fetch_url URL TAG -> prints path of raw body on stdout; reuses cache on
# 304 Not Modified or on any curl failure (offline resilience).
fetch_url() {
  local url="$1" tag="$2"
  local key raw etag code modified
  key="$(sha1 "$url")"
  raw="$STATE/cache/$tag-$key.body"
  etag="$STATE/etags/$tag-$key.etag"
  local -a conditional=(--etag-save "$etag")
  [ -s "$etag" ] && conditional+=(--etag-compare "$etag")
  if [ ! -s "$etag" ] && [ -s "$raw" ]; then
    modified=$(date -Ru -r "$raw" 2>/dev/null || true)
    [ -n "$modified" ] && conditional+=(--time-cond "$modified")
  fi
  code=$(curl -sS --max-time 25 --max-filesize "$MAX_BYTES" \
    -A "$UA" --compressed "${conditional[@]}" \
    -o "$raw.new" -w '%{http_code}' "$url" 2>>"$STATE/fetch.log") || code="000"
  case "$code" in
    200)
      [ -s "$raw.new" ] && mv -f "$raw.new" "$raw" || rm -f "$raw.new"
      printf '200\n' >"$STATE/.fetch-code-$key"
      printf '%s' "$raw"
      ;;
    304)
      rm -f "$raw.new"
      # Refresh mtime so the age-based prune below never evicts a feed
      # that is still being polled (content just happens to be unchanged).
      [ -f "$raw" ] && touch "$raw"
      [ -f "$etag" ] && touch "$etag"
      printf '304\n' >"$STATE/.fetch-code-$key"
      [ -f "$raw" ] && printf '%s' "$raw"
      ;;
    *)
      rm -f "$raw.new"
      printf '%s\n' "$code" >"$STATE/.fetch-code-$key"
      # Offline or server error: fall back to the last good body, if any.
      [ -f "$raw" ] && printf '%s' "$raw"
      ;;
  esac
}

to_epoch() { # date string -> epoch or 0
  local out
  out=$(date -d "$1" +%s 2>/dev/null) && printf '%s' "$out" || printf '0'
}

strip_newlines() { tr -d '\r\n' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'; }

# One xpath call per item: concat() with a separator nobody uses in titles.
rss_item() { # file index -> TSV-ish row
  local file="$1" i="$2"
  xmllint --recover --xpath \
    "concat(string((//item)[$i]/title),'$SEP',string((//item)[$i]/link),'$SEP',string((//item)[$i]/pubDate),'$SEP',string((//item)[$i]/guid),'$SEP',substring(normalize-space(string((//item)[$i]/description)),1,280))" \
    "$file" 2>/dev/null | strip_newlines
}

atom_entry() { # file index -> TSV-ish row
  local file="$1" i="$2" e
  e="(//*[local-name()='entry'])[$i]"
  xmllint --recover --xpath \
    "concat(string($e/*[local-name()='title']),'$SEP',string($e/*[local-name()='link'][@rel='alternate'][1]/@href|$e/*[local-name()='link'][1]/@href),'$SEP',string($e/*[local-name()='updated']|$e/*[local-name()='published']),'$SEP',string($e/*[local-name()='id']),'$SEP',substring(normalize-space(string($e/*[local-name()='summary']|$e/*[local-name()='content'])),1,280))" \
    "$file" 2>/dev/null | strip_newlines
}

parse_rss() { # rawfile feedname maxitems outfile
  local file="$1" feed="$2" max="$3" out="$4"
  local root count i row title link pub guid desc epoch id score comments hnid tmp
  root=$(xmllint --recover --xpath 'name(/*)' "$file" 2>/dev/null | strip_newlines)
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  : >"$tmp.items"
  if [ "$root" = "feed" ]; then
    count=$(xmllint --recover --xpath 'count(//*[local-name()="entry"])' "$file" 2>/dev/null | cut -d. -f1)
    [ "$count" -gt "$max" ] && count="$max"
    i=1
    while [ "$i" -le "$count" ]; do
      row=$(atom_entry "$file" "$i")
      title=${row%%"$SEP"*}; row=${row#*"$SEP"}
      link=${row%%"$SEP"*}; row=${row#*"$SEP"}
      pub=${row%%"$SEP"*}; row=${row#*"$SEP"}
      guid=${row%%"$SEP"*}; desc=${row#*"$SEP"}
      [ -z "$title" ] && title="$desc"
      [ -z "$title" ] && { i=$((i + 1)); continue; }
      [ -z "$link" ] && link="$guid"
      epoch=$(to_epoch "$pub")
      id=$(sha1 "${guid:-$link}")
      jq -n --arg id "$id" --arg title "$title" --arg link "$link" \
        --arg feed "$feed" --argjson published "$epoch" \
        --arg excerpt "$desc" \
        '{id:$id,title:$title,link:$link,feed:$feed,published:$published,score:null,commentsUrl:null,hnId:null,excerpt:$excerpt}' >>"$tmp.items"
      i=$((i + 1))
    done
  else
    count=$(xmllint --recover --xpath 'count(//item)' "$file" 2>/dev/null | cut -d. -f1)
    [ "$count" -gt "$max" ] && count="$max"
    i=1
    while [ "$i" -le "$count" ]; do
      row=$(rss_item "$file" "$i")
      title=${row%%"$SEP"*}; row=${row#*"$SEP"}
      link=${row%%"$SEP"*}; row=${row#*"$SEP"}
      pub=${row%%"$SEP"*}; row=${row#*"$SEP"}
      guid=${row%%"$SEP"*}; desc=${row#*"$SEP"}
      [ -z "$title" ] && { i=$((i + 1)); continue; }
      [ -z "$link" ] && link="$guid"
      epoch=$(to_epoch "$pub")
      # RSS excerpts often contain markup; avoid an HTML parser for plain text.
      if [[ "$desc" == *'<'* ]]; then
        desc=$(printf '%s' "$desc" | xmllint --html --recover --xpath 'string(//body)' - 2>/dev/null | head -c 280)
      fi
      # hackernewsrss-style digests embed score + thread link in the excerpt.
      score=$(printf '%s' "$desc" | grep -o '[0-9]\+ points' | head -1 | grep -o '[0-9]\+' || true)
      hnid=$(printf '%s' "$desc" | grep -o 'item?id=[0-9]\+' | head -1 | cut -d= -f2 || true)
      comments=""
      [ -n "$hnid" ] && comments="https://news.ycombinator.com/item?id=$hnid"
      id=$(sha1 "${guid:-$link}")
      if [ -n "$score" ]; then score_json="$score"; else score_json=null; fi
      jq -n --arg id "$id" --arg title "$title" --arg link "$link" \
        --arg feed "$feed" --argjson published "$epoch" \
        --argjson score "$score_json" --arg comments "$comments" \
        --arg hnid "${hnid:-}" --arg excerpt "$desc" \
        '{id:$id,title:$title,link:$link,feed:$feed,published:$published,score:$score,commentsUrl:(if $comments == "" then null else $comments end),hnId:(if $hnid == "" then null else ($hnid|tonumber) end),excerpt:$excerpt}' >>"$tmp.items"
      i=$((i + 1))
    done
  fi
  jq -s '.' "$tmp.items" 2>/dev/null | atomic_write "$out" || printf '[]' | atomic_write "$out"
  rm -f "$tmp.items" "$tmp"
}

parse_jsonfeed() { # rawfile feedname maxitems outfile
  local file="$1" feed="$2" max="$3" out="$4"
  local tmp n i title link pub epoch id
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  : >"$tmp.items"
  n=$(jq -r '.items | length' "$file" 2>/dev/null || echo 0)
  [ "$n" -gt "$max" ] && n="$max"
  i=0
  while [ "$i" -lt "$n" ]; do
    title=$(jq -r ".items[$i].title // empty" "$file" 2>/dev/null)
    link=$(jq -r ".items[$i].url // empty" "$file" 2>/dev/null)
    pub=$(jq -r ".items[$i].date_published // empty" "$file" 2>/dev/null)
    [ -z "$title" ] && { i=$((i + 1)); continue; }
    epoch=$(to_epoch "$pub")
    id=$(sha1 "${link:-$title}")
    jq -n --arg id "$id" --arg title "$title" --arg link "$link" \
      --arg feed "$feed" --argjson published "$epoch" \
      '{id:$id,title:$title,link:$link,feed:$feed,published:$published,score:null,commentsUrl:null,hnId:null,excerpt:""}' >>"$tmp.items"
    i=$((i + 1))
  done
  jq -s '.' "$tmp.items" 2>/dev/null | atomic_write "$out" || printf '[]' | atomic_write "$out"
  rm -f "$tmp.items" "$tmp"
}

hn_items() { # kind count feedlabel outfile
  local kind="$1" count="$2" feed="$3" out="$4"
  local ids id args f tmp
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  ids=$(curl -sS --max-time 20 -A "$UA" --compressed "$HN_API/${kind}stories.json" 2>>"$STATE/fetch.log" \
    | jq -r ".[0:$count][]" 2>/dev/null) || ids=""
  if [ -z "$ids" ]; then printf '[]' | atomic_write "$out"; rm -f "$tmp"; return 0; fi
  args=()
  for id in $ids; do
    f="$STATE/hn/$id.json"
    if [ ! -s "$f" ]; then args+=(-o "$f.part-$$" "$HN_API/item/$id.json"); fi
  done
  if [ "${#args[@]}" -gt 0 ]; then
    # shellcheck disable=SC2086
    curl -sS --max-time 25 --parallel --parallel-max 8 -A "$UA" --compressed "${args[@]}" >>"$STATE/fetch.log" 2>&1 || true
  fi
  # Publish atomically so parallel poll jobs never read a partial item.
  for id in $ids; do
    f="$STATE/hn/$id.json"
    pf="$f.part-$$"
    if [ -s "$pf" ] && [ ! -s "$f" ]; then mv -f "$pf" "$f"; else rm -f "$pf"; fi
  done
  : >"$tmp.items"
  for id in $ids; do
    f="$STATE/hn/$id.json"
    [ -s "$f" ] || continue
    jq --arg feed "$feed" '
      select(. != null and .deleted != true and .dead != true and .title != null)
      | {id: ("hn\(.id)"), title: .title,
         link: (if .url != null then .url else ("https://news.ycombinator.com/item?id=\(.id)") end),
         feed: $feed, published: (.time // 0), score: (.score // null),
         descendants: (.descendants // null),
         commentsUrl: ("https://news.ycombinator.com/item?id=\(.id)"),
         hnId: .id, excerpt: (.text // "" | gsub("<[^>]+>"; "") | .[0:200])}' \
      "$f" 2>/dev/null >>"$tmp.items" || true
  done
  jq -s '.' "$tmp.items" 2>/dev/null | atomic_write "$out" || printf '[]' | atomic_write "$out"
  rm -f "$tmp.items" "$tmp"
}

# ------------------------------------------------------------------ poll ---

# --------------------------------------------------------------- feed spec ---
# Parse one feeds.txt line into SPEC_* globals. Supported forms:
#   hn:top:30 | https://url | Label | url | url | max:N | Label | url | max:N
# A leading "!" disables the line (fetch_source returns 2 = skipped).
SPEC_KIND=""; SPEC_LABEL=""; SPEC_URL=""; SPEC_MAX=0
parse_feed_spec() { # line
  local line="$1" part rest hkind hcount
  SPEC_KIND="rss"; SPEC_LABEL=""; SPEC_URL=""; SPEC_MAX=0
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$line" in ''|\#*) return 1 ;; esac
  case "$line" in '!'*) return 2 ;; esac
  # Split on "|" via parameter expansion (no word splitting, so URL
  # query strings like ?x=1 survive glob-free).
  rest="$line|"
  while [ -n "$rest" ]; do
    part="${rest%%|*}"
    rest="${rest#*|}"
    part="$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$part" ] && continue
    case "$part" in
      [Mm][Aa][Xx]:*)
        SPEC_MAX="$(printf '%s' "$part" | cut -d: -f2 | tr -cd '0-9')"
        [ -z "$SPEC_MAX" ] && SPEC_MAX=0
        ;;
      [Hh][Nn]:*)
        hkind="$(printf '%s' "$part" | cut -d: -f2 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        hcount="$(printf '%s' "$part" | cut -d: -f3 | tr -cd '0-9')"
        case "$hkind" in top|best|new|ask|show|job|jobs) ;; *) hkind="top" ;; esac
        [ "$hkind" = "jobs" ] && hkind="job"
        SPEC_KIND="hn"
        SPEC_URL="hn:$hkind"
        [ -n "$hcount" ] && SPEC_URL="$SPEC_URL:$hcount"
        ;;
      [Hh][Tt][Tt][Pp]*://*)
        SPEC_KIND="rss"; SPEC_URL="$part"
        ;;
      *)
        SPEC_LABEL="$part"
        ;;
    esac
  done
  [ -z "$SPEC_URL" ] && return 1
  if [ "$SPEC_KIND" = "rss" ] && [ -z "$SPEC_LABEL" ]; then
    SPEC_LABEL="$(printf '%s' "$SPEC_URL" | sed 's#https\?://##; s#/.*##')"
  fi
  if [ "$SPEC_KIND" = "hn" ] && [ -z "$SPEC_LABEL" ]; then
    SPEC_LABEL="HN $(printf '%s' "$SPEC_URL" | cut -d: -f2)"
  fi
  return 0
}

# Normalized key for dedupe/compare: hn lowercased, URLs host-lowercased
# with trailing slashes stripped.
feed_key() { # line -> key on stdout
  local key scheme rest host path
  parse_feed_spec "$1" || return 1
  if [ "$SPEC_KIND" = "hn" ]; then
    printf '%s' "$SPEC_URL" | tr '[:upper:]' '[:lower:]'
  else
    key="$(printf '%s' "$SPEC_URL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    scheme="$(printf '%s' "$key" | grep -o '^[Hh][Tt][Tt][Pp][Ss]\?://' | tr '[:upper:]' '[:lower:]')"
    rest="${key#*://}"
    host="$(printf '%s' "$rest" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
    path="$(printf '%s' "$rest" | cut -d/ -f2- -s)"
    if [ -z "$path" ] || [ "$path" = "$rest" ]; then
      printf '%s%s' "$scheme" "$host"
    else
      path="$(printf '/%s' "$path" | sed -E 's#/+$##')"
      [ "$path" = "/" ] && path=""
      printf '%s%s%s' "$scheme" "$host" "$path"
    fi
  fi
}

fetch_source() { # line index : fetch+parse ONE source into .src.N.json ; exit 1 on failure
  local line="$1" n="$2" kind count feed raw max per
  parse_feed_spec "$line" || return 1
  per="$SPEC_MAX"
  [ "$per" -le 0 ] 2>/dev/null && per="$MAX_PER_FEED"
  feed="$SPEC_LABEL"
  case "$SPEC_KIND" in
    hn)
      kind=$(printf '%s' "$SPEC_URL" | cut -d: -f2)
      count=$(printf '%s' "$SPEC_URL" | cut -d: -f3)
      case "$kind" in top|best|new|ask|show|job) ;; *) kind="top" ;; esac
      case "$count" in ''|*[!0-9]*) count="$STORY_COUNT" ;; esac
      [ -z "$feed" ] && feed="HN $kind"
      hn_items "$kind" "$count" "$feed" "$STATE/.src.$n.json" || return 1
      printf '%s' "$feed" >"$STATE/.src.$n.label"
      ;;
    *)
      raw=$(fetch_url "$SPEC_URL" "rss")
      [ -n "$raw" ] || return 1
      sha1 "$SPEC_URL" >"$STATE/.src.$n.urlkey"
      if head -c 200 "$raw" | grep -q '"version"[[:space:]]*:[[:space:]]*"https://jsonfeed.org'; then
        parse_jsonfeed "$raw" "$feed" "$per" "$STATE/.src.$n.json"
      else
        parse_rss "$raw" "$feed" "$per" "$STATE/.src.$n.json"
      fi
      printf '%s' "$feed" >"$STATE/.src.$n.label"
      ;;
  esac
}

do_poll() {
  read_config
  local feeds="$STATE/feeds.txt" errors=0 parts=() source_lines=() source_keys=() n=0 line
  [ -f "$feeds" ] || { printf '[]' | atomic_write "$STATE/items.json"; return 0; }
  # Phase 1: fetch+parse every source with at most 8 in flight.
  local running=0
  declare -A seen_source=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in ''|\#*|'!'*) continue ;; esac
    local dkey
    dkey=$(feed_key "$line" 2>/dev/null) || continue
    [ -n "${seen_source["$dkey"]:-}" ] && continue
    seen_source["$dkey"]=1
    n=$((n + 1))
    fetch_source "$line" "$n" >>"$STATE/fetch.log" 2>&1 &
    running=$((running + 1))
    if [ "$running" -ge 8 ]; then wait -n; running=$((running - 1)); fi
    parts+=("$STATE/.src.$n.json")
    source_lines+=("$line")
    source_keys+=("$dkey")
  done <"$feeds"
  wait
  if [ "$n" -eq 0 ]; then
    printf '[]' | atomic_write "$STATE/items.json"
    jq -n --argjson updated "$(now_epoch)" \
      '{updatedAt:$updated, ok:true, errors:0, count:0, perFeed:[]}' \
      | atomic_write "$STATE/status.json"
    return 0
  fi
  # Phase 2: merge. Sources that failed keep no file; count them as errors.
  local merged=() perfeed_tmp ok_i
  perfeed_tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  : >"$perfeed_tmp"
  for ((ok_i=0; ok_i<${#parts[@]}; ok_i++)); do
    local f="${parts[$ok_i]}" lbl cnt ok
    lbl=""; [ -f "$STATE/.src.$((ok_i + 1)).label" ] && lbl="$(cat "$STATE/.src.$((ok_i + 1)).label")"
    [ -z "$lbl" ] && lbl="${source_lines[$ok_i]}"
    if [ -s "$f" ]; then merged+=("$f"); ok=true; else printf '[]' >"$f"; merged+=("$f"); errors=$((errors + 1)); ok=false; fi
    cnt="$(jq 'length' "$f" 2>/dev/null || echo 0)"
    jq -n --arg feed "$lbl" --arg key "${source_keys[$ok_i]}" --argjson ok "$ok" --argjson count "$cnt" \
      '{feed:$feed,key:$key,ok:$ok,count:$count}' >>"$perfeed_tmp"
  done
  { local changed=0
    for ((source_no=0; source_no<${#parts[@]}; source_no++)); do
      f="${parts[$source_no]}"
      if [ -f "$f" ]; then
        local ukey source_line
        source_line="${source_lines[$source_no]}"
        if parse_feed_spec "$source_line" 2>/dev/null && [ "$SPEC_KIND" = "hn" ]; then
          changed=1
        elif [ -f "$STATE/.src.$((source_no + 1)).urlkey" ]; then
          ukey="$(cat "$STATE/.src.$((source_no + 1)).urlkey")"
          [ "$(cat "$STATE/.fetch-code-$ukey" 2>/dev/null)" != 304 ] && changed=1
        else
          changed=1
        fi
      fi
    done
    if [ "$changed" -eq 0 ] && [ -s "$STATE/items.json" ]; then
      : # Every RSS source was unchanged; keep the existing merged list.
    else
    jq -s '[.[].[]] | unique_by(.id) | sort_by(.published) | reverse | .[0:500]' \
      "${merged[@]}" 2>/dev/null | atomic_write "$STATE/items.json" \
      || printf '[]' | atomic_write "$STATE/items.json"
    fi
  }
  rm -f "$STATE"/.src.*.json "$STATE"/.src.*.label "$STATE"/.src.*.urlkey
  rm -f "$STATE"/.fetch-code-*
  jq -n --argjson updated "$(now_epoch)" --argjson errors "$errors" \
    --argjson count "$(jq 'length' "$STATE/items.json" 2>/dev/null || echo 0)" \
    --slurpfile perfeed "$perfeed_tmp" \
    '{updatedAt:$updated, ok: ($errors == 0), errors:$errors, count:$count, perFeed:$perfeed}' \
    | atomic_write "$STATE/status.json"
  rm -f "$perfeed_tmp"
}

# --------------------------------------------------------------- comments ---

clean_html() { # stdin -> plain text; entity-aware via libxml2
  xmllint --html --recover --xpath 'string(//body)' - 2>/dev/null \
    | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | head -c 4000
}

fetch_ids() { # id... : fetch any missing HN items in ONE parallel batch
  local args=() id
  for id in "$@"; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ -s "$STATE/hn/$id.json" ] || args+=(-o "$STATE/hn/$id.json" "$HN_API/item/$id.json")
  done
  if [ "${#args[@]}" -gt 0 ]; then
    # shellcheck disable=SC2086
    curl -sS --max-time 25 --parallel --parallel-max 8 -A "$UA" --compressed "${args[@]}" >>"$STATE/fetch.log" 2>&1 || true
  fi
}

kids_of() { # id limit : prints kid ids, one per line
  local f="$STATE/hn/$1.json"
  [ -s "$f" ] || return 0
  jq -r --argjson n "$2" '.kids // [] | .[0:$n][]' "$f" 2>/dev/null || true
}

do_comments() { # HNID ; prints thread json path
  local id="$1" tmp out raw_text f
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || exit 1
  out="$STATE/thread-$id.json"
  # Breadth-first, three parallel batches: story, <=12 top kids, <=5 nested each.
  fetch_ids "$id"
  : >"$tmp.l1"
  kids_of "$id" 12 >"$tmp.l1"
  # shellcheck disable=SC2013,SC2046
  fetch_ids $(cat "$tmp.l1")
  : >"$tmp.l2"
  # shellcheck disable=SC2013
  for f in $(cat "$tmp.l1"); do kids_of "$f" 5 >>"$tmp.l2"; done
  sort -u "$tmp.l2" -o "$tmp.l2"
  # shellcheck disable=SC2046
  fetch_ids $(cat "$tmp.l2")
  # Assemble the nested thread from cache with one jq pass (no network).
  : >"$tmp.flist"
  for f in "$id" $(cat "$tmp.l1" "$tmp.l2"); do
    [ -s "$STATE/hn/$f.json" ] && printf '%s\n' "$STATE/hn/$f.json" >>"$tmp.flist"
  done
  # shellcheck disable=SC2046
  jq -s 'map(select(. != null and .id != null) | {(.id|tostring): .}) | add // {}' \
    $(cat "$tmp.flist") 2>/dev/null >"$tmp.byid" || printf '{}' >"$tmp.byid"
  jq --argjson rootid "$id" --slurpfile d "$tmp.byid" -n '
    ($d[0]) as $dict
    | def node($nid; $depth):
        ($dict[$nid|tostring]) as $me
        | select($me != null and $me.deleted != true and $me.dead != true)
        | (if $depth == 0 then 12 else 5 end) as $b
        | {id: $me.id, by: ($me.by // "?"), time: ($me.time // 0),
           text: ($me.text // ""), score: ($me.score // 0), depth: $depth,
           kids: [$me.kids // [] | .[0:$b][] | node(tostring; $depth + 1)]};
      node($rootid; 0)' 2>/dev/null >"$tmp.thread" || printf '{}' >"$tmp.thread"
  jq -c '.' "$tmp.thread" 2>/dev/null >"$tmp.compact" || printf '{}' >"$tmp.compact"
  # Clean every distinct text field through libxml2 (entity + tag aware).
  jq -c '.. | objects | .text // empty' "$tmp.compact" | sort -u >"$tmp.uniq"
  : >"$tmp.map"
  while IFS= read -r raw_text; do
    [ -z "$raw_text" ] && continue
    cleaned=$(printf '%s' "$raw_text" | clean_html)
    jq -n --arg k "$raw_text" --arg v "$cleaned" '{($k): $v}' >>"$tmp.map"
  done <"$tmp.uniq"
  jq -s 'add // {}' "$tmp.map" 2>/dev/null >"$tmp.dict" || printf '{}' >"$tmp.dict"
  jq --slurpfile dict "$tmp.dict" '
    def fix: if type == "object"
             then with_entries(if .key == "text" and ($dict[0][.value] != null) then .value = $dict[0][.value] else .value |= fix end)
             elif type == "array" then map(fix) else . end;
    fix' "$tmp.compact" 2>/dev/null | atomic_write "$out" || atomic_write "$out" <"$tmp.compact"
  rm -f "$tmp"*
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------- article ---

# Body text that means "anti-bot challenge page" rather than the article.
# Only consulted for SHORT extractions: a long page merely discussing these
# topics keeps its text, while a stripped-down challenge page (typically a
# single "Enable JavaScript…" line) is caught here.
is_blocked_text() {
  LC_ALL=C grep -qiE \
    'enable javascript and cookies|cf_chl_|checking your browser before accessing|attention required! \| cloudflare|pardon our interruption|making sure you.re not a bot' \
    "$1" 2>/dev/null
}

# Honest placeholder for pages the reader could not turn into text —
# challenge HTML, HTTP errors, empty extractions. do_summarize recognises
# the first line and never pipes this into the AI.
article_placeholder() { # DEST HINT
  {
    printf "This page couldn't be loaded in the reader%s.\n\n" "$2"
    printf 'Press o to open it in your browser instead.\n'
  } | atomic_write "$1"
}

do_article() { # URL ; prints cache path
  local url="$1" key raw out tmp i count para code bytes
  key=$(sha1 "$url")
  raw="$STATE/articles/$key.html"
  out="$STATE/articles/$key.txt"
  # Follow redirects (browsers do; a 301 target used to yield an empty
  # extraction) and record the final status to reject error pages early.
  code=$(curl -sS -L --max-redirs 5 --max-time 20 --max-filesize 2097152 \
    "${ARTICLE_CURL[@]}" --compressed -o "$raw" -w '%{http_code}' \
    "$url" 2>>"$STATE/fetch.log") || code="000"
  if [ "$code" = "000" ] || [ ! -s "$raw" ]; then
    rm -f "$raw"
    article_placeholder "$out" " (network error)"
    printf '%s\n' "$out"
    return 0
  fi
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  if [ "$code" != "200" ]; then
    rm -f "$tmp" "$raw"
    article_placeholder "$out" " (HTTP $code)"
    printf '%s\n' "$out"
    return 0
  fi
  count=$(xmllint --html --recover --xpath 'count(//p[not(ancestor::noscript)])' "$raw" 2>/dev/null | cut -d. -f1)
  [ -z "$count" ] && count=0
  [ "$count" -gt 40 ] && count=40
  i=1
  : >"$tmp.txt"
  while [ "$i" -le "$count" ]; do
    para=$(xmllint --html --recover --xpath "normalize-space(string((//p[not(ancestor::noscript)])[${i}]))" "$raw" 2>/dev/null)
    if [ "${#para}" -ge 40 ]; then printf '%s\n\n' "$para" >>"$tmp.txt"; fi
    i=$((i + 1))
  done
  if [ ! -s "$tmp.txt" ]; then
    # string(//body) also dumped inline <script> contents — that is how
    # Cloudflare's challenge JS leaked into articles. Take only text nodes
    # outside script/style/noscript instead.
    xmllint --html --recover --xpath \
      '//body//text()[not(ancestor::script) and not(ancestor::style) and not(ancestor::noscript)]' \
      "$raw" 2>/dev/null | strip_newlines | head -c 12000 >"$tmp.txt" || true
  fi
  bytes=$(wc -c <"$tmp.txt" 2>/dev/null || printf 0)
  if [ ! -s "$tmp.txt" ] || [ "$bytes" -lt 60 ] ||
    { [ "$bytes" -lt 800 ] && is_blocked_text "$tmp.txt"; }; then
    rm -f "$tmp.txt" "$tmp" "$raw"
    article_placeholder "$out" ""
    printf '%s\n' "$out"
    return 0
  fi
  head -c 20000 "$tmp.txt" | atomic_write "$out"
  # Only the .txt is ever read (reader + summarize); the raw HTML is
  # re-downloaded on every open anyway, so drop it instead of letting it
  # accumulate — it was 6.8M after two days of normal use.
  rm -f "$tmp.txt" "$tmp" "$raw"
  printf '%s\n' "$out"
}

# ----------------------------------------------------------------- digest ---

do_digest() {
  local items="$STATE/items.json" readf="$STATE/read.json" top summary digest
  [ -f "$items" ] || return 0
  [ -f "$readf" ] || printf '{"ids":[]}' >"$readf"
  digest="$STATE/digest.md"
  top=$(jq --slurpfile read "$readf" '
    (($read[0].ids // []) | map({(.): true}) | add // {}) as $seen
    | map(select($seen[.id] != true)) | sort_by(.score // 0) | reverse | .[0:8]' \
    "$items" 2>/dev/null) || top="[]"
  {
    printf '# Herald briefing — %s\n\n' "$(date '+%A, %B %d')"
    printf '%s' "$top" | jq -r '.[] | "- [\(.title)](\(.link))" + (if .score then " — \(.score) pts" else "" end) + (if .commentsUrl then " ([thread](\(.commentsUrl)))" else "" end)'
    printf '\n_Generated locally by Herald._\n'
  } | atomic_write "$digest"
  summary=$(printf '%s' "$top" | jq -r '.[0:5] | map(.title) | join("\n• ")' 2>/dev/null)
  if [ -n "$summary" ] && command -v notify-send >/dev/null 2>&1; then
    notify-send "Herald — morning briefing" "• $summary" 2>/dev/null || true
  fi
  date '+%Y-%-m-%-d' >"$STATE/digest-day.txt"
  printf '%s\n' "$digest"
}

# Warm a tiny cache for the first few unread stories without delaying polling.
# This runs as a separate service process and is intentionally capped at 3.
do_prefetch() {
  local id url
  [ -s "$STATE/items.json" ] || return 0
  while IFS=$'\t' read -r id url; do
    [ -n "$url" ] || continue
    if [[ "$id" == hn* ]]; then
      do_comments "${id#hn}"
    fi
    do_article "$url" >/dev/null 2>&1 || true
  done < <(jq -r --slurpfile r "$STATE/read.json" '
    (($r[0].ids // []) | map({(.):true}) | add // {}) as $seen
    | map(select($seen[.id] != true)) | .[0:3][] | [.id, .link] | @tsv
  ' "$STATE/items.json" 2>/dev/null)
}

# ------------------------------------------------------------- prune ---
# Size discipline for the state dir, run after every poll. Everything
# pruned here is regenerable: article extracts re-curl on open, HN
# payloads re-fetch on the next poll, threads re-fetch on "c". The two
# stateful files are capped at write time instead: read.json = 800 ids,
# items.json = 500 items.
do_prune() {
  # Article extracts: 7 days old OR beyond the newest 100 files.
  find "$STATE/articles" -type f -mtime +7 -delete 2>/dev/null || true
  ls -t "$STATE"/articles/* 2>/dev/null | tail -n +101 | xargs -r rm -f --
  # Raw HTML leftovers (only written by older builds; new do_article drops
  # it inline). 60-minute grace so an in-flight extraction is never hit.
  find "$STATE/articles" -name '*.html' -mmin +60 -delete 2>/dev/null || true
  # HN payloads: 14 days (front-page stories churn much faster).
  find "$STATE/hn" -type f -mtime +14 -delete 2>/dev/null || true
  # Assembled comment threads: 7 days.
  find "$STATE" -maxdepth 1 -name 'thread-*.json' -mtime +7 -delete 2>/dev/null || true
  # Feed bodies + ETags: age together — an ETag without its body would
  # make fetch_url treat a fresh 304 as a failure.
  find "$STATE/cache" "$STATE/etags" -type f -mtime +14 -delete 2>/dev/null || true
  # Temp files from interrupted runs.
  find "$STATE" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null || true
  # fetch.log: keep a 1000-line tail once it passes 256 KiB.
  local logsz
  logsz=$(stat -c %s "$STATE/fetch.log" 2>/dev/null || echo 0)
  if [ "$logsz" -gt 262144 ]; then
    tail -n 1000 "$STATE/fetch.log" | atomic_write "$STATE/fetch.log"
  fi
}

# ------------------------------------------------------------ write-config ---

do_write_config() { # JSON
  printf '%s' "$3" | jq -e . >/dev/null 2>&1 || exit 1
  printf '%s' "$3" | jq '{refreshMinutes, storyCount, maxItemsPerFeed, digestTime, aiEnabled, aiCommand, showScores}' \
    | atomic_write "$STATE/config.json"
  # feeds.txt = settings feeds + Panel-added feeds (panel-feeds.txt), deduped
  # by normalized key. Panel additions survive settings syncs; removing a
  # feed from Bar settings removes it (unless also Panel-added).
  local incoming="$STATE/.incoming-feeds.$$" merged="$STATE/.merged-feeds.$$"
  printf '%s' "$3" | jq -r '.feeds // [] | .[]' 2>/dev/null >"$incoming" || : >"$incoming"
  : >"$merged"
  declare -A seen_write=()
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$trimmed" in ''|\#*) printf '%s\n' "$line" >>"$merged"; continue ;; esac
    key=$(feed_key "$line" 2>/dev/null) || { printf '%s\n' "$line" >>"$merged"; continue; }
    [ -n "${seen_write["$key"]:-}" ] && continue
    seen_write["$key"]=1
    printf '%s\n' "$line" >>"$merged"
  done <"$incoming"
  if [ -f "$STATE/panel-feeds.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      case "$trimmed" in ''|\#*) continue ;; esac
      # A leading "!" disables without deleting: key on the stripped form
      # but preserve the line verbatim.
      kline="$trimmed"
      case "$kline" in '!'*) kline="$(printf '%s' "$kline" | sed 's/^![[:space:]]*//')" ;; esac
      key=$(feed_key "$kline" 2>/dev/null) || continue
      [ -n "${seen_write["$key"]:-}" ] && continue
      seen_write["$key"]=1
      printf '%s\n' "$line" >>"$merged"
    done <"$STATE/panel-feeds.txt"
  fi
  cat "$merged" | atomic_write "$STATE/feeds.txt"
  rm -f "$incoming" "$merged"
}

# ---------------------------------------------------------------- add-feed ---
# Append a feed line if its normalized key is not already present.
# Prints the resulting feeds.txt path. Exit 2 on duplicate, 1 on bad input.

do_add_feed() { # LINE
  local line="${3:?add-feed needs a feed line}" key existing ekey
  case "$line" in ''|\#*) exit 1 ;; esac
  key=$(feed_key "$line") || exit 1
  [ -f "$STATE/feeds.txt" ] || : >"$STATE/feeds.txt"
  [ -f "$STATE/panel-feeds.txt" ] || : >"$STATE/panel-feeds.txt"
  while IFS= read -r existing || [ -n "$existing" ]; do
    ekey=$(feed_key "$existing" 2>/dev/null) || continue
    [ "$ekey" = "$key" ] && exit 2
  done <"$STATE/feeds.txt"
  printf '%s\n' "$line" >>"$STATE/feeds.txt"
  printf '%s\n' "$line" >>"$STATE/panel-feeds.txt"
  printf '%s\n' "$STATE/feeds.txt"
}

# Remove every feeds.txt line whose normalized key matches the given line/URL.
# Also drops it from panel-feeds.txt so a later settings sync won't re-add it.
do_remove_feed() { # LINE-or-URL
  local line="${3:?remove-feed needs a feed line or URL}" key tmp removed=0
  key=$(feed_key "$line" 2>/dev/null) || key="$line"
  [ -f "$STATE/feeds.txt" ] || exit 0
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || exit 1
  while IFS= read -r existing || [ -n "$existing" ]; do
    ekey=$(feed_key "$existing" 2>/dev/null) || { printf '%s\n' "$existing" >>"$tmp"; continue; }
    if [ "$ekey" = "$key" ]; then removed=$((removed + 1)); else printf '%s\n' "$existing" >>"$tmp"; fi
  done <"$STATE/feeds.txt"
  cat "$tmp" | atomic_write "$STATE/feeds.txt"
  if [ -f "$STATE/panel-feeds.txt" ]; then
    : >"$tmp"
    while IFS= read -r existing || [ -n "$existing" ]; do
      ekey=$(feed_key "$existing" 2>/dev/null) || { printf '%s\n' "$existing" >>"$tmp"; continue; }
      [ "$ekey" = "$key" ] || printf '%s\n' "$existing" >>"$tmp"
    done <"$STATE/panel-feeds.txt"
    cat "$tmp" | atomic_write "$STATE/panel-feeds.txt"
  fi
  rm -f "$tmp"
  printf '%d\n' "$removed"
}

# Fetch one URL and report item count without touching state (for Add UI).
do_probe() { # URL
  local url="${3:?probe needs URL}" raw tmp n
  case "$url" in http://*|https://*) ;; *) printf '{"ok":false,"error":"need http(s) URL"}\n'; exit 1 ;; esac
  read_config
  raw=$(fetch_url "$url" "probe")
  [ -n "$raw" ] || { printf '{"ok":false,"error":"fetch failed"}\n'; exit 1; }
  tmp="$STATE/.probe.$$.json"
  if head -c 200 "$raw" | grep -q '"version"[[:space:]]*:[[:space:]]*"https://jsonfeed.org'; then
    parse_jsonfeed "$raw" probe "$MAX_PER_FEED" "$tmp"
  else
    parse_rss "$raw" probe "$MAX_PER_FEED" "$tmp"
  fi
  n="$(jq 'length' "$tmp" 2>/dev/null || echo 0)"
  rm -f "$tmp"
  jq -n --argjson count "$n" '{ok: ($count > 0), count: $count}'
}

# --------------------------------------------------------------- summarize ---
# Pipe a cached article file into the user's AI command (stdin -> stdout).
# Runs only when the user explicitly asks for a summary in the reader.

do_summarize() { # CACHEFILE AICOMMAND...
  local cache="$3"
  shift 3
  [ -f "$cache" ] || exit 1
  [ "$#" -gt 0 ] || exit 1
  # Placeholder pages never reach the AI — answer directly, no API call.
  if head -c 300 "$cache" | grep -qF "couldn't be loaded in the reader"; then
    printf 'No article text to summarize — the site blocked the reader. Press o to open it in the browser.'
    return 0
  fi
  head -c 12000 "$cache" | "$@" 2>>"$STATE/fetch.log" | head -c 4000
}

# --------------------------------------------------------------- read state ---
do_mark_read() { # ID
  [ -f "$STATE/read.json" ] || printf '{"ids":[]}' >"$STATE/read.json"
  jq --arg id "$3" '.ids += [$id] | .ids |= (unique | .[-800:]) | {ids: .ids}' \
    "$STATE/read.json" 2>/dev/null | atomic_write "$STATE/read.json"
}

do_mark_all_read() {
  jq --slurpfile items "$STATE/items.json" '{ids: ($items[0] | map(.id))}' -n 2>/dev/null \
    | atomic_write "$STATE/read.json" || printf '{"ids":[]}' | atomic_write "$STATE/read.json"
}

case "$MODE" in
  poll) do_poll ;;
  prefetch) do_prefetch ;;
  prune) do_prune ;;
  comments) do_comments "${3:?comments needs HNID}" ;;
  article) do_article "${3:?article needs URL}" ;;
  digest) do_digest ;;
  write-config) do_write_config "$@" ;;
  mark-read) do_mark_read "$@" ;;
  mark-all-read) do_mark_all_read ;;
  summarize) do_summarize "$@" ;;
  add-feed) do_add_feed "$@" ;;
  remove-feed) do_remove_feed "$@" ;;
  probe) do_probe "$@" ;;
  *) printf 'unknown mode: %s\n' "$MODE" >&2; exit 1 ;;
esac
