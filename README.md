# Herald

Fast, keyboard-first RSS and Hacker News reader for Omarchy Quattro, with a
daily morning briefing. Bar pill with a rotating headline, a popup story list,
and a fullscreen reader with article text, HN comment threads, and opt-in AI
summaries.

Built on the zero-build stack: all network and XML work runs in `fetch.sh`
(`curl` + `xmllint` + `jq`, all guaranteed on Omarchy) outside the shell
process. QML only reads the JSON cache, so raw payloads never touch shell
memory. No daemons, no build step, no accounts.

## Install

```bash
omarchy plugin add https://github.com/<you>/herald.git --enable
```

The widget lands in the right section of the bar. Move it any time:

```bash
omarchy bar move kshitij.herald --section right
```

Requires only what Omarchy already ships: `curl`, `jq`, `xmllint`
(`libxml2`), `xdg-open`, `notify-send`. Optional: a local AI command such as
`ollama run llama3.1` for summaries.

## Use it

| Input | Action |
|---|---|
| Click pill | Open / close the story popup |
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

Default sources: `hn:top:30` plus `https://hackernewsrss.com/feed.xml`.
Change them in the widget settings (one source per line — an RSS/Atom/JSON
feed URL, or `hn:top`, `hn:best`, `hn:new`, `hn:ask`, `hn:show`, `hn:jobs`
with an optional `:count` suffix).

The service polls in the background even while the panel is closed, keeps an
offline cache, and posts a morning briefing notification at Digest time
(`~/.local/state/omarchy/herald/digest.md` keeps the markdown).

### Command line

```bash
omarchy-shell kshitij.herald ping
omarchy-shell kshitij.herald status
omarchy-shell kshitij.herald refresh
omarchy-shell kshitij.herald digest
omarchy-shell kshitij.herald open 0      # open the Nth story
omarchy-shell shell summon kshitij.herald '"{}"'
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

State lives under `~/.local/state/omarchy/herald/` (`items.json`,
`read.json`, `config.json`, `feeds.txt`, `digest.md`, per-feed ETag cache).
Remote content is parsed, never executed; article text is rendered as
`Text.PlainText`; AI runs only when you enable it and press `s`, piping
cached article text to your own command on stdin.

## Update and remove

```bash
omarchy plugin update kshitij.herald
omarchy-restart-shell
```

```bash
omarchy plugin remove kshitij.herald
rm -rf ~/.local/state/omarchy/herald   # optional: erase cache + read state
```

## Development

```bash
node test/test-model.cjs
bash -n fetch.sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Service.qml BarWidget.qml Panel.qml Reader.qml
```

Edit the checkout at `~/.config/omarchy/plugins/kshitij.herald/` — the shell
hot-reloads on save (`keepLoaded` services need `omarchy-restart-shell`).

MIT licensed.
