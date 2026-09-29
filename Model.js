// OmaBrief Model.js — pure logic, no Qt or Quickshell imports, so it stays
// unit-testable under plain node. QML files import it as `import "Model.js" as Model`.

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10)
  if (isNaN(n)) return fallback
  if (n < min) return min
  if (n > max) return max
  return n
}

function parseFeeds(text, fallback) {
  var out = []
  var lines = String(text === undefined || text === null ? (fallback || "") : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "" || line.charAt(0) === "#") continue
    out.push(line)
  }
  return out
}

function isHnSource(line) {
  return String(line).indexOf("hn:") === 0
}

// Structured feed spec. Supported line formats (one per line):
//   hn:top:30
//   https://example.com/feed.xml
//   Label | https://example.com/feed.xml
//   https://example.com/feed.xml | max:20
//   Label | https://example.com/feed.xml | max:20
//   Label | hn:top:20
// A leading "!" disables the line without deleting it.
function parseFeedSpec(line) {
  var raw = String(line === undefined || line === null ? "" : line)
  var text = raw.replace(/^\s+|\s+$/g, "")
  if (text === "" || text.charAt(0) === "#") return null
  var disabled = false
  if (text.charAt(0) === "!") {
    disabled = true
    text = text.slice(1).replace(/^\s+|\s+$/g, "")
    if (text === "") return null
  }
  var parts = text.split("|")
  for (var i = 0; i < parts.length; i++) parts[i] = parts[i].replace(/^\s+|\s+$/g, "")
  var spec = { raw: raw, disabled: disabled, kind: "rss", url: "", label: "", max: 0, count: 0 }
  for (var j = 0; j < parts.length; j++) {
    var p = parts[j]
    if (/^max\s*:\s*\d+\s*$/i.test(p)) {
      spec.max = parseInt(p.split(":")[1], 10)
    } else if (/^hn\s*:/i.test(p)) {
      var segs = p.split(":")
      var kind = (segs[1] || "top").replace(/\s+/g, "").toLowerCase()
      if (["top", "best", "new", "ask", "show", "job", "jobs"].indexOf(kind) === -1) kind = "top"
      if (kind === "jobs") kind = "job"
      var count = parseInt(segs[2], 10)
      spec.kind = "hn"
      spec.url = "hn:" + kind + (isNaN(count) ? "" : ":" + count)
      spec.count = isNaN(count) ? 0 : count
      if (!spec.label) spec.label = "HN " + kind
    } else if (/^https?:\/\//i.test(p)) {
      spec.kind = "rss"
      spec.url = p
    } else if (p !== "") {
      spec.label = p
    }
  }
  if (spec.url === "") return null
  return spec
}

// Canonical key for dedupe: hn spec as-is (lowercased kind), URLs trimmed
// with trailing slashes stripped and host lowercased.
function feedKey(specOrLine) {
  var spec = typeof specOrLine === "object" ? specOrLine : parseFeedSpec(specOrLine)
  if (!spec) return ""
  if (spec.kind === "hn") return spec.url.toLowerCase()
  var m = String(spec.url).match(/^(https?:\/\/)([^\/]+)(.*)$/i)
  if (!m) return String(spec.url).replace(/^\s+|\s+$/g, "")
  var rest = m[3].replace(/\/+$/, "")
  return m[1].toLowerCase() + m[2].toLowerCase() + rest
}

// Union setting feeds with state-file feeds (Panel-added), deduped.
function mergeFeeds(primary, secondary) {
  var seen = {}
  var out = []
  var lists = [primary || [], secondary || []]
  for (var l = 0; l < lists.length; l++) {
    for (var i = 0; i < lists[l].length; i++) {
      var line = lists[l][i]
      var key = feedKey(line)
      if (key === "" || seen[key]) continue
      seen[key] = true
      out.push(String(line).replace(/^\s+|\s+$/g, ""))
    }
  }
  return out
}

function feedLabel(source) {
  var spec = parseFeedSpec(source)
  if (spec && spec.label) return spec.label
  if (spec && spec.kind === "hn") return spec.label
  if (isHnSource(source)) {
    var kind = String(source).split(":")[1] || "top"
    return "HN " + kind
  }
  var m = String(source).match(/^(?:https?:\/\/)?([^\/]+)/)
  return m ? m[1] : String(source)
}

// "2h ago" style labels from epoch seconds.
function relativeTime(epochSeconds, nowSeconds) {
  var now = nowSeconds || Math.floor(Date.now() / 1000)
  var delta = now - (epochSeconds || 0)
  if (delta < 0) delta = 0
  if (delta < 60) return "just now"
  var minutes = Math.floor(delta / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(months / 12) + "y ago"
}

function scoreText(item, showScores) {
  if (!showScores) return ""
  var parts = []
  if (item.score !== null && item.score !== undefined) parts.push("\u25b2" + item.score)
  if (item.descendants !== null && item.descendants !== undefined) parts.push(item.descendants + " comments")
  return parts.join(" · ")
}

// Filter + search over the item array. Query matches title, excerpt and feed.
function filterItems(items, query, feedFilter, hideRead, readIds) {
  var q = String(query || "").toLowerCase()
  var out = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    if (feedFilter && feedFilter !== "" && it.feed !== feedFilter) continue
    if (hideRead && readIds && readIds[it.id]) continue
    if (q !== "") {
      var hay = ((it.title || "") + " " + (it.excerpt || "") + " " + (it.feed || "")).toLowerCase()
      if (hay.indexOf(q) === -1) continue
    }
    out.push(it)
  }
  return out
}

function feedNames(items) {
  var seen = {}
  var out = []
  for (var i = 0; i < items.length; i++) {
    var f = items[i].feed || "unknown"
    if (!seen[f]) { seen[f] = true; out.push(f) }
  }
  out.sort()
  return out
}

function unreadCount(items, readIds) {
  var n = 0
  for (var i = 0; i < items.length; i++) {
    if (!readIds || !readIds[items[i].id]) n++
  }
  return n
}

function parseReadJson(text) {
  try {
    var data = JSON.parse(text || '{"ids":[]}')
    var map = {}
    var ids = data.ids || []
    for (var i = 0; i < ids.length; i++) map[ids[i]] = true
    return map
  } catch (e) {
    return {}
  }
}

function serializeReadJson(readIds, cap) {
  var ids = []
  for (var k in readIds) if (readIds[k]) ids.push(k)
  // No reliable insertion order guarantee needed: cap by truncation.
  if (ids.length > (cap || 800)) ids = ids.slice(ids.length - (cap || 800))
  return JSON.stringify({ ids: ids })
}

// Flatten an HN thread ({kids:[...]} nested) into rows with depth.
function flattenThread(node, out) {
  out = out || []
  if (!node) return out
  var kids = node.kids || []
  for (var i = 0; i < kids.length; i++) {
    var k = kids[i]
    out.push({ by: k.by || "?", time: k.time || 0, text: k.text || "", score: k.score || 0, depth: k.depth || 0 })
    if (k.kids && k.kids.length) {
      for (var j = 0; j < k.kids.length; j++) {
        var g = k.kids[j]
        out.push({ by: g.by || "?", time: g.time || 0, text: g.text || "", score: g.score || 0, depth: (g.depth !== undefined ? g.depth : (k.depth || 0) + 1) })
        if (g.kids && g.kids.length) flattenThread({ kids: g.kids }, out)
      }
    }
  }
  return out
}

// Digest is due when HH:MM today has passed and none was written today.
function digestDue(digestTime, lastDigestDay, nowDate) {
  if (!digestTime || digestTime.indexOf(":") === -1) return false
  var parts = String(digestTime).split(":")
  var h = parseInt(parts[0], 10), m = parseInt(parts[1], 10)
  if (isNaN(h) || isNaN(m)) return false
  var now = nowDate || new Date()
  var dayKey = now.getFullYear() + "-" + (now.getMonth() + 1) + "-" + now.getDate()
  if (lastDigestDay === dayKey) return false
  var due = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0)
  return now.getTime() >= due.getTime()
}

// Node test harness compatibility: export when running outside QML.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    clampInt: clampInt, parseFeeds: parseFeeds, isHnSource: isHnSource,
    parseFeedSpec: parseFeedSpec, feedKey: feedKey, mergeFeeds: mergeFeeds,
    feedLabel: feedLabel, relativeTime: relativeTime, scoreText: scoreText,
    filterItems: filterItems, feedNames: feedNames, unreadCount: unreadCount,
    parseReadJson: parseReadJson, serializeReadJson: serializeReadJson,
    flattenThread: flattenThread, digestDue: digestDue
  }
}
