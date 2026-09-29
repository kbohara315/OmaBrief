# OmaBrief

Fast, keyboard-first RSS and Hacker News reader for Omarchy Quattro, with a
daily morning briefing. Bar pill with a rotating headline, a popup story list,
and a fullscreen reader with article text, HN comment threads, and opt-in AI
summaries.

Built on the zero-build stack: all network and XML work runs in `fetch.sh`
(`curl` + `xmllint` + `jq`, all guaranteed on Omarchy) outside the shell
process. QML only reads the JSON cache, so raw payloads never touch shell
memory. No daemons, no build step, no accounts.

The bar shows a single icon — headlines live in the hover tooltip, so long
titles never push other widgets aside.

## Install

```bash
omarchy plugin add https://github.com/<you>/omabrief.git --enable
```

The widget lands in the right section of the bar. Move it any time:

```bash
omarchy bar move kshitij.omabrief --section right
```

Requires only what Omarchy already ships: `curl`, `jq`, `xmllint`
(`libxml2`), `xdg-open`, `notify-send`. Optional: a local AI command such as
`ollama run llama3.1` for summaries.

## Use it

| Input | Action |
|---|---|
| `SUPER + ALT + H` | Toggle the stories popup from anywhere |
| Click icon | Open / close the story popup |
| Middle-click pill | Refresh now |
| Right-click pill | Fullscreen reader for the top story |
| `j` / `k`, `↑` / `↓` | Move selection |
| `/` | Search |
| `Enter` | Open article in browser (marks read) |
| `c` / middle-click story | HN thread in the fullscreen reader |
| `r` | Refresh now |
| `a` | Mark all read |
| `u` | Toggle unread-only |
| `o` / `t` / `a` / `s` / `Esc` (reader) | Open original, thread view, article view, AI summary, close |

### Global shortcut

The service registers `omabrief:omabrief-toggle` via Hyprland's global-shortcuts
protocol (visible in `hyprctl globalshortcuts`). Bind it in
`~/.config/hypr/bindings.lua`:

```lua
hl.bind("SUPER + ALT + H", hl.dsp.global("omabrief:omabrief-toggle"), { description = "OmaBrief stories" })
```

Default sources: `hn:top:30` plus `https://hackernewsrss.com/feed.xml`.
Change them in the widget settings (one source per line — an RSS/Atom/JSON
feed URL, or `hn:top`, `hn:best`, `hn:new`, `hn:ask`, `hn:show`, `hn:jobs`
with an optional `:count` suffix). Any feed can take a custom label and a
per-feed cap, and `!` disables a line without deleting it:

```
hn:top:30
TechCrunch | https://techcrunch.com/feed/ | max:20
https://lobste.rs/rss
!https://noisy.example.com/feed.xml
```

Or press `+` in the stories popup to add a feed (URL + optional label)
without opening settings. Popup-added feeds show a `×` on their chip to
remove them; feeds from widget settings are managed there. Read/unread
tracking, search, feed chips, and the morning digest cover every feed, not
just Hacker News; the thread view only appears for stories with an HN
discussion.

The service polls in the background even while the panel is closed, keeps an
offline cache, and posts a morning briefing notification at Digest time
(`~/.local/state/omarchy/omabrief/digest.md` keeps the markdown).

Reader keys: `a` article text, `t` HN thread, `o`/`Enter` open in the
browser, `s` AI summary, `+`/`-` bigger/smaller reading text, `0` reset text
size, `Esc` close. Sites that block automated readers (Cloudflare
challenges and friends) get a clear "couldn't be loaded" placeholder with
the `press o` fallback instead of raw JavaScript.

### Command line

```bash
omarchy-shell kshitij.omabrief ping
omarchy-shell kshitij.omabrief status
omarchy-shell kshitij.omabrief refresh
omarchy-shell kshitij.omabrief digest
omarchy-shell kshitij.omabrief open 0      # open the Nth story
omarchy-shell kshitij.omabrief add "https://lobste.rs/rss"
omarchy-shell kshitij.omabrief remove "https://lobste.rs/rss"   # settings-listed feeds return on the next settings sync; delete them in widget settings
omarchy-shell kshitij.omabrief feeds       # list configured sources
omarchy-shell shell summon kshitij.omabrief '"{}"'
```

## Files

```
manifest.json   kinds: ["service","bar-widget"], keepLoaded service
Service.qml     background poller, read-state, digest timer, IPC target
BarWidget.qml   headline pill, ticker, settings sync, popup/reader loaders
Panel.qml       story popup (search, feed chips, keyboard list)
Reader.qml      fullscreen article + HN thread + opt-in AI summary
Model.js        pure formatting/filter logic (unit-tested under node)
fetch.sh        fetch + parse + cache + digest helper (curl/xmllint/jq)
test/           node tests for Model.js
```

State lives under `~/.local/state/omarchy/omabrief/` (`items.json`,
`read.json`, `config.json`, `feeds.txt`, `panel-feeds.txt` for popup-added
feeds, `digest.md`, per-feed ETag cache, per-feed health in `status.json`).
Remote content is parsed, never executed; article text is rendered as
`Text.PlainText`; AI runs only when you enable it and press `s`, piping
cached article text to your own command on stdin.

## Update and remove

```bash
omarchy plugin update kshitij.omabrief
omarchy-restart-shell
```

```bash
omarchy plugin remove kshitij.omabrief
rm -rf ~/.local/state/omarchy/omabrief   # optional: erase cache + read state
```

## Development

```bash
node test/test-model.cjs
bash -n fetch.sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Service.qml BarWidget.qml Panel.qml Reader.qml
```

Edit the checkout at `~/.config/omarchy/plugins/kshitij.omabrief/` — the shell
hot-reloads on save (`keepLoaded` services need `omarchy-restart-shell`).

MIT licensed.
