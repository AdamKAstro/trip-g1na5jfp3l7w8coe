"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const seed = require("../kids-seed.js");

test("Fahrenheit normals round to the nearest Celsius without extra precision", function () {
  assert.equal(seed.cFromF(44.3), 7);
  assert.equal(seed.cFromF(33.8), 1);
  assert.equal(seed.cFromF(37.5), 3);
  assert.equal(seed.cFromF(20.6), -6);
  assert.equal(seed.cFromF(48.8), 9);
  assert.equal(seed.cFromF(34.5), 1);
  assert.equal(seed.cFromF(78.2), 26);
  assert.equal(seed.cFromF(64.3), 18);
  assert.equal(seed.roundHalfUp(30.2), 30);
  assert.equal(seed.roundHalfUp(23.9), 24);
});

test("every climate row cites a source, a period, and a station", function () {
  assert.ok(seed.CLIMATE.length >= 8);
  for (const row of seed.CLIMATE) {
    assert.equal(row.available, true);
    assert.equal(Number.isInteger(row.highC), true);
    assert.equal(Number.isInteger(row.lowC), true);
    assert.match(row.period, /19|20/);
    assert.match(row.sourceUrl, /^https:\/\//);
    assert.ok(row.station.length > 3);
    assert.match(row.note, /not a forecast/i);
    assert.ok(row.highC > row.lowC);
  }
});

test("cruise piers and sea days do not invent temperatures", function () {
  for (const key of ["costa-maya", "roatan", "cozumel", "cococay", "sea"]) {
    const row = seed.climateFor(key, 1);
    assert.equal(row.available, false);
    assert.equal(row.highC, undefined);
    assert.equal(row.lowC, undefined);
    assert.match(row.reason, /not|no /i);
  }
});

test("itinerary months pick December or January and never overwrite the stop", function () {
  const singapore = seed.ITINERARY[0];
  const presented = seed.presentStop(singapore);
  assert.equal(presented.stop.title, "Singapore");
  assert.equal(presented.stop.summary, singapore.summary);
  assert.equal(presented.climate.length, 1);
  assert.equal(presented.climate[0].month, 12);
  assert.equal(presented.climate[0].highC, 30);
  assert.equal(presented.climate[0].lowC, 24);
  const vero = seed.ITINERARY.find(function (s) { return s.placeKey === "vero"; });
  const both = seed.presentStop(vero);
  assert.deepEqual(both.climate.map(function (c) { return c.month; }), [12, 1]);
  assert.equal(both.climate[0].highC, 24);
  assert.equal(both.climate[1].highC, 23);
  assert.equal(both.stop.title, vero.title);
  const swapped = seed.presentStop(vero, [{ placeKey: "vero", month: 12, available: true, highC: 1, lowC: 0 }]);
  assert.equal(swapped.stop.title, vero.title);
  assert.equal(swapped.stop.summary, vero.summary);
  assert.equal(swapped.climate[0].highC, 1);
  assert.equal(swapped.climate[1].highC, 23);
});

test("seeded plan has no prices, confirmation codes or passport numbers", function () {
  const blob = JSON.stringify({ stops: seed.ITINERARY, packing: seed.PACKING, note: seed.PLAN_NOTE });
  assert.doesNotMatch(blob, /US\$|A\$|AUD |S\$|cabin \d|confirmation code|passport number/i);
  assert.match(seed.PLAN_NOTE, /not a confirmation/i);
  assert.match(seed.CRUISE_NOTE, /3 January/);
  assert.equal(seed.ITINERARY.some(function (s) { return s.title === "CocoCay" && s.startsOn === "2027-01-09"; }), true);
  assert.equal(seed.ITINERARY.some(function (s) { return /Islamorada|Keys night is booked/i.test(s.summary); }), false);
});

test("migration contains the same itinerary titles and does not grant anon writes", function () {
  const sql = fs.readFileSync("supabase/migrations/20261109010000_kids_area.sql", "utf8");
  for (const stop of seed.ITINERARY) {
    assert.ok(sql.includes(stop.title), "missing title " + stop.title);
    assert.ok(sql.includes(stop.startsOn), "missing date " + stop.startsOn);
  }
  for (const row of seed.CLIMATE) {
    assert.ok(sql.includes(String(row.highC)), "missing high " + row.highC);
    assert.ok(sql.includes(row.placeKey));
  }
  assert.match(sql, /revoke all on table public\.packing_items from public, anon, authenticated/i);
  assert.match(sql, /trip_role', 'child'/);
  assert.doesNotMatch(sql, /service_role/);
  assert.doesNotMatch(sql, /sb_secret/);
});

test("service worker still bypasses Supabase and caches the kids scripts", function () {
  const sw = fs.readFileSync("sw.js", "utf8");
  assert.match(sw, /supabase\.co/);
  assert.match(sw, /kids-seed\.js/);
  assert.match(sw, /kids-sync\.js/);
  assert.match(sw, /kids-ui\.js/);
  assert.match(sw, /trip-shell-v4-20261109/);
  assert.doesNotMatch(sw, /service_role/);
});

test("starter packing ids are stable per child", function () {
  assert.equal(seed.packingId(1, 1), "b0000001-0000-4000-8000-000100000001");
  assert.equal(seed.packingId(4, 18), "b0000001-0000-4000-8000-000400000018");
  assert.equal(seed.PACKING.length, 18);
  assert.equal(seed.CHILDREN.length, 4);
});
