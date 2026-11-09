"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createPackingSync, createItineraryCache, createMemoryServer, memoryStorage } = require("../kids-sync.js");

function ids() {
  let n = 0;
  return function () {
    n += 1;
    return "00000000-0000-4000-8000-" + String(n).padStart(12, "0");
  };
}
function clock() {
  let n = 0;
  return function () {
    n += 1;
    return "2026-11-08T00:00:" + String(n).padStart(2, "0") + ".000Z";
  };
}

async function setup(extra) {
  const storage = memoryStorage();
  const server = createMemoryServer();
  let online = true;
  const sync = createPackingSync(Object.assign({
    storage: storage,
    transport: server,
    isOnline: function () { return online; },
    newId: ids(),
    now: clock()
  }, extra || {}));
  await sync.load();
  return { sync: sync, server: server, storage: storage, setOnline: function (v) { online = v; } };
}

test("offline add survives reload and flushes once", async function () {
  const storage = memoryStorage();
  const server = createMemoryServer();
  let online = false;
  const a = createPackingSync({ storage: storage, transport: server, isOnline: function () { return online; }, newId: ids(), now: clock() });
  await a.load();
  await a.add("c0a1d000-0000-4000-8000-000000000001", { title: "Beanie", category: "Snow" });
  assert.equal(a.status().state, "offline");
  assert.match(a.status().label, /not saved/i);
  assert.equal(a.status().label.includes("Saved"), false);
  assert.equal(server.rows.size, 0);
  const b = createPackingSync({ storage: storage, transport: server, isOnline: function () { return online; }, newId: ids(), now: clock() });
  await b.load();
  assert.equal(b.items()[0].title, "Beanie");
  assert.equal(b.ops().length, 1);
  const opId = b.ops()[0].opId;
  online = true;
  await b.flush();
  assert.equal(b.status().state, "saved");
  assert.equal(server.peek(b.items()[0].id).version, 1);
  assert.equal(server.peek(b.items()[0].id).title, "Beanie");
  await b.flush();
  assert.equal(server.peek(b.items()[0].id).version, 1);
  assert.equal(b.ops().length, 0);
  assert.equal(opId.length > 10, true);
});

test("retries of the same op do not double-apply", async function () {
  const server = createMemoryServer();
  let fail = true;
  const transport = {
    apply: async function (op) {
      const res = await server.apply(op);
      if (fail) { fail = false; throw new Error("dropped response"); }
      return { status: "duplicate", item: res.item };
    },
    pull: function () { return server.pull(); }
  };
  const { sync } = await setup({ transport: transport, storage: memoryStorage() });
  await sync.add("c0a1d000-0000-4000-8000-000000000001", { title: "Socks" });
  await sync.flush();
  const row = server.peek(sync.items()[0].id);
  assert.equal(row.version, 1);
  assert.equal(row.title, "Socks");
  assert.equal(sync.status().state, "saved");
});

test("coalesced edits send one op", async function () {
  const { sync, server, setOnline } = await setup();
  setOnline(false);
  await sync.add("c0a1d000-0000-4000-8000-000000000001", { title: "Hat" });
  await sync.edit(sync.items()[0].id, { title: "Sun hat", qty: 2 });
  await sync.toggle(sync.items()[0].id);
  assert.equal(sync.ops().length, 1);
  setOnline(true);
  await sync.flush();
  const row = server.peek(sync.items()[0].id);
  assert.equal(row.version, 1);
  assert.equal(row.title, "Sun hat");
  assert.equal(row.qty, 2);
  assert.equal(row.checked, true);
});

test("two sessions: stale edit does not wipe the newer title", async function () {
  const server = createMemoryServer();
  const storeA = memoryStorage();
  const storeB = memoryStorage();
  const A = createPackingSync({ storage: storeA, transport: server, isOnline: function () { return true; }, newId: ids(), now: clock() });
  const B = createPackingSync({ storage: storeB, transport: server, isOnline: function () { return true; }, newId: ids(), now: clock() });
  await A.load();
  await A.add("c0a1d000-0000-4000-8000-000000000001", { title: "Coat" });
  await A.flush();
  await B.load(true);
  assert.equal(B.items()[0].title, "Coat");
  assert.equal(B.items()[0].version, 1);
  await A.edit(A.items()[0].id, { title: "Warm coat" });
  await A.flush();
  assert.equal(server.peek(A.items()[0].id).title, "Warm coat");
  assert.equal(server.peek(A.items()[0].id).version, 2);
  await B.edit(B.items()[0].id, { title: "Old coat" });
  await B.flush();
  assert.equal(server.peek(A.items()[0].id).title, "Warm coat");
  assert.equal(server.peek(A.items()[0].id).version, 2);
  assert.equal(B.items()[0].title, "Warm coat");
  assert.equal(B.takeConflict().itemId, A.items()[0].id);
});

test("check, uncheck, delete and undo", async function () {
  const { sync, server } = await setup();
  await sync.add("c0a1d000-0000-4000-8000-000000000001", { title: "Gloves", category: "Snow" });
  await sync.flush();
  const id = sync.items()[0].id;
  await sync.toggle(id);
  await sync.flush();
  assert.equal(server.peek(id).checked, true);
  await sync.undo();
  await sync.flush();
  assert.equal(server.peek(id).checked, false);
  await sync.remove(id);
  assert.equal(sync.items().length, 0);
  await sync.undo();
  assert.equal(sync.items().length, 1);
  await sync.flush();
  assert.equal(server.peek(id).deleted_at, null);
  await sync.remove(id);
  await sync.flush();
  assert.ok(server.peek(id).deleted_at);
  assert.equal(sync.items().length, 0);
});

test("itinerary snapshot keeps the last sync time and does not claim a fresh save", async function () {
  const storage = memoryStorage();
  const cache = createItineraryCache(storage);
  assert.equal(await cache.load(), null);
  await cache.save([{ id: "a", title: "Singapore" }], "2026-12-01T00:00:00.000Z");
  const again = createItineraryCache(storage);
  const snap = await again.load();
  assert.equal(snap.rows[0].title, "Singapore");
  assert.equal(snap.syncedAt, "2026-12-01T00:00:00.000Z");
});

test("remote note ignores a stale updated_at while a local op is pending", async function () {
  const { sync, setOnline } = await setup();
  setOnline(false);
  await sync.add("c0a1d000-0000-4000-8000-000000000001", { title: "Mine" });
  const id = sync.allItems()[0].id;
  sync.noteRemote({ id: id, child_id: "c0a1d000-0000-4000-8000-000000000001", title: "Theirs", version: 4, updated_at: "2026-12-02T00:00:00.000Z", deleted_at: null, checked: false });
  assert.equal(sync.items()[0].title, "Mine");
});
