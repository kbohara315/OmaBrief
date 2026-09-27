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
  local key raw etag code
  key="$(sha1 "$url")"
  raw="$STATE/cache/$tag-$key.body"
  etag="$STATE/etags/$tag-$key.etag"
  code=$(curl -sS --max-time 25 --max-filesize "$MAX_BYTES" \
    -A "$UA" --compressed \
    ${etag:+--etag-compare "$etag"} --etag-save "$etag" \
    -o "$raw.new" -w '%{http_code}' "$url" 2>>"$STATE/fetch.log") || code="000"
  case "$code" in
    200)
      [ -s "$raw.new" ] && mv -f "$raw.new" "$raw" || rm -f "$raw.new"
      printf '%s' "$raw"
      ;;
    304)
      rm -f "$raw.new"
      [ -f "$raw" ] && printf '%s' "$raw"
      ;;
    *)
      rm -f "$raw.new"
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
    if [ ! -s "$f" ]; then args+=(-o "$f" "$HN_API/item/$id.json"); fi
  done
  if [ "${#args[@]}" -gt 0 ]; then
    # shellcheck disable=SC2086
    curl -sS --max-time 25 --parallel --parallel-max 8 -A "$UA" --compressed "${args[@]}" >>"$STATE/fetch.log" 2>&1 || true
  fi
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

do_poll() {
  read_config
  local feeds="$STATE/feeds.txt" errors=0 parts=() n=0 line src kind count feed root raw
  [ -f "$feeds" ] || { printf '[]' | atomic_write "$STATE/items.json"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    case "$line" in
      hn:*)
        kind=$(printf '%s' "$line" | cut -d: -f2)
        count=$(printf '%s' "$line" | cut -d: -f3)
        case "$kind" in top|best|new|ask|show|job) ;; *) kind="top" ;; esac
        case "$count" in ''|*[!0-9]*) count="$STORY_COUNT" ;; esac
        hn_items "$kind" "$count" "HN $kind" "$STATE/.src.$n.json" \
          || { printf '[]' | atomic_write "$STATE/.src.$n.json"; errors=$((errors + 1)); }
        ;;
      *)
        raw=$(fetch_url "$line" "rss")
        if [ -n "$raw" ]; then
          feed=$(printf '%s' "$line" | sed 's#https\?://##; s#/.*##')
          if head -c 200 "$raw" | grep -q '"version"[[:space:]]*:[[:space:]]*"https://jsonfeed.org'; then
            parse_jsonfeed "$raw" "$feed" "$MAX_PER_FEED" "$STATE/.src.$n.json"
          else
            parse_rss "$raw" "$feed" "$MAX_PER_FEED" "$STATE/.src.$n.json"
          fi
        else
          printf '[]' | atomic_write "$STATE/.src.$n.json"; errors=$((errors + 1))
        fi
        ;;
    esac
    parts+=("$STATE/.src.$n.json")
  done <"$feeds"
  if [ "$n" -eq 0 ]; then printf '[]' | atomic_write "$STATE/items.json"; else
    jq -s '[.[].[]] | unique_by(.id) | sort_by(.published) | reverse | .[0:500]' \
      "${parts[@]}" 2>/dev/null | atomic_write "$STATE/items.json" \
      || printf '[]' | atomic_write "$STATE/items.json"
  fi
  rm -f "$STATE"/.src.*.json
  jq -n --argjson updated "$(now_epoch)" --argjson errors "$errors" \
    --argjson count "$(jq 'length' "$STATE/items.json" 2>/dev/null || echo 0)" \
    '{updatedAt:$updated, ok: ($errors == 0), errors:$errors, count:$count}' \
    | atomic_write "$STATE/status.json"
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

do_article() { # URL ; prints cache path
  local url="$1" key raw tmp i count para
  key=$(sha1 "$url")
  raw="$STATE/articles/$key.html"
  curl -sS --max-time 20 --max-filesize 2097152 -A "$UA" --compressed \
    -o "$raw" "$url" 2>>"$STATE/fetch.log" || { rm -f "$raw"; return 1; }
  [ -s "$raw" ] || return 1
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || return 1
  count=$(xmllint --html --recover --xpath 'count(//p)' "$raw" 2>/dev/null | cut -d. -f1)
  [ -z "$count" ] && count=0
  [ "$count" -gt 40 ] && count=40
  i=1
  : >"$tmp.txt"
  while [ "$i" -le "$count" ]; do
    para=$(xmllint --html --recover --xpath "normalize-space(string((//p)[$i]))" "$raw" 2>/dev/null)
    if [ "${#para}" -ge 40 ]; then printf '%s\n\n' "$para" >>"$tmp.txt"; fi
    i=$((i + 1))
  done
  if [ ! -s "$tmp.txt" ]; then
    xmllint --html --recover --xpath 'normalize-space(string(//body))' "$raw" 2>/dev/null | head -c 12000 >"$tmp.txt" || true
  fi
  head -c 20000 "$tmp.txt" | atomic_write "$STATE/articles/$key.txt"
  rm -f "$tmp.txt" "$tmp"
  printf '%s\n' "$STATE/articles/$key.txt"
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

# ------------------------------------------------------------ write-config ---

do_write_config() { # JSON
  printf '%s' "$3" | jq -e . >/dev/null 2>&1 || exit 1
  printf '%s' "$3" | jq '{refreshMinutes, storyCount, maxItemsPerFeed, digestTime, aiEnabled, aiCommand, showScores}' \
    | atomic_write "$STATE/config.json"
  printf '%s' "$3" | jq -r '.feeds // [] | .[]' 2>/dev/null | atomic_write "$STATE/feeds.txt"
}

# --------------------------------------------------------------- summarize ---
# Pipe a cached article file into the user's AI command (stdin -> stdout).
# Runs only when the user explicitly asks for a summary in the reader.

do_summarize() { # CACHEFILE AICOMMAND...
  local cache="$3"
  shift 3
  [ -f "$cache" ] || exit 1
  [ "$#" -gt 0 ] || exit 1
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
  comments) do_comments "${3:?comments needs HNID}" ;;
  article) do_article "${3:?article needs URL}" ;;
  digest) do_digest ;;
  write-config) do_write_config "$@" ;;
  mark-read) do_mark_read "$@" ;;
  mark-all-read) do_mark_all_read ;;
  summarize) do_summarize "$@" ;;
  *) printf 'unknown mode: %s\n' "$MODE" >&2; exit 1 ;;
esac
