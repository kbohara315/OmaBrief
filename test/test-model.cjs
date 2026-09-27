const assert = require("node:assert/strict");
const M = require("../Model.js");

// clampInt
assert.equal(M.clampInt("15", 10, 2, 60), 15);
assert.equal(M.clampInt("abc", 10, 2, 60), 10);
assert.equal(M.clampInt("1", 10, 2, 60), 2);
assert.equal(M.clampInt("99", 10, 2, 60), 60);

// parseFeeds
assert.deepEqual(M.parseFeeds("hn:top:30\nhttps://a.com/x.xml\n# c\n  \n", ""), ["hn:top:30", "https://a.com/x.xml"]);
assert.deepEqual(M.parseFeeds(undefined, "hn:new"), ["hn:new"]);

// feedLabel
assert.equal(M.feedLabel("hn:top:30"), "HN top");
assert.equal(M.feedLabel("https://hackernewsrss.com/feed.xml"), "hackernewsrss.com");

// relativeTime
assert.equal(M.relativeTime(1000, 1030), "just now");
assert.equal(M.relativeTime(1000, 1000 + 5 * 60), "5m ago");
assert.equal(M.relativeTime(1000, 1000 + 3 * 3600), "3h ago");
assert.equal(M.relativeTime(1000, 1000 + 9 * 86400), "9d ago");

// filterItems
const items = [
  { id: "a", title: "NixOS desktop", excerpt: "", feed: "HN top" },
  { id: "b", title: "Go SIMD", excerpt: "compiler stuff", feed: "go.dev" },
  { id: "c", title: "Gravity holographic", excerpt: "", feed: "HN top" },
];
assert.equal(M.filterItems(items, "", "", false, {}).length, 3);
assert.equal(M.filterItems(items, "simd", "", false, {}).length, 1);
assert.equal(M.filterItems(items, "", "HN top", false, {}).length, 2);
assert.equal(M.filterItems(items, "", "", true, { a: true }).length, 2);
assert.deepEqual(M.feedNames(items), ["HN top", "go.dev"]);
assert.equal(M.unreadCount(items, { a: true }), 2);

// read json round-trip + cap
const map = M.parseReadJson('{"ids":["a","b"]}');
assert.ok(map.a && map.b);
assert.deepEqual(M.parseReadJson("garbage"), {});
const big = {};
for (let i = 0; i < 900; i++) big["id" + i] = true;
assert.ok(JSON.parse(M.serializeReadJson(big, 800)).ids.length === 800);

// flattenThread
const thread = { kids: [{ by: "a", time: 1, text: "t1", depth: 0, kids: [{ by: "b", time: 2, text: "t2", depth: 1, kids: [] }] }] };
const flat = M.flattenThread(thread);
assert.equal(flat.length, 2);
assert.equal(flat[1].depth, 1);

// digestDue
assert.equal(M.digestDue("", null, new Date(2026, 8, 27, 10, 0)), false);
assert.equal(M.digestDue("09:00", null, new Date(2026, 8, 27, 10, 0)), true);
assert.equal(M.digestDue("09:00", null, new Date(2026, 8, 27, 8, 0)), false);
assert.equal(M.digestDue("09:00", "2026-9-27", new Date(2026, 8, 27, 10, 0)), false);

console.log("Model.js: all tests passed");
