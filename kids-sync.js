/* Packing sync: durable local queue, idempotent retries, stale writes do not replace newer rows.
   Itinerary cache is read-only and labelled with the last successful sync time. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.TripSync = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function clone(v) {
    return v == null ? v : JSON.parse(JSON.stringify(v));
  }

  function memoryStorage(seed) {
    const data = Object.assign({}, seed || {});
    return {
      async get(key) { return clone(data[key]); },
      async set(key, value) { data[key] = clone(value); }
    };
  }

  function idbStorage(name) {
    const dbp = new Promise(function (resolve, reject) {
      const req = indexedDB.open(name || "usa-trip-kids", 1);
      req.onupgradeneeded = function () {
        const db = req.result;
        if (!db.objectStoreNames.contains("kv")) db.createObjectStore("kv");
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
    return {
      async get(key) {
        const db = await dbp;
        return new Promise(function (resolve, reject) {
          const tx = db.transaction("kv", "readonly");
          const req = tx.objectStore("kv").get(key);
          req.onsuccess = function () { resolve(req.result); };
          req.onerror = function () { reject(req.error); };
        });
      },
      async set(key, value) {
        const db = await dbp;
        return new Promise(function (resolve, reject) {
          const tx = db.transaction("kv", "readwrite");
          tx.objectStore("kv").put(value, key);
          tx.oncomplete = function () { resolve(); };
          tx.onerror = function () { reject(tx.error); };
        });
      }
    };
  }

  function desiredOf(row) {
    return {
      title: row.title,
      qty: row.qty == null || row.qty === "" ? null : Number(row.qty),
      category: row.category || null,
      checked: !!row.checked,
      deleted: !!row.deleted_at,
      suggested: !!row.suggested
    };
  }

  function sameDesired(a, b) {
    return JSON.stringify(desiredOf(a)) === JSON.stringify(b);
  }

  function createPackingSync(opts) {
    const storage = opts.storage;
    const transport = opts.transport;
    const now = opts.now || function () { return new Date().toISOString(); };
    const newId = opts.newId || function () {
      if (globalThis.crypto && crypto.randomUUID) return crypto.randomUUID();
      return "xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx".replace(/x/g, function () {
        return Math.floor(Math.random() * 16).toString(16);
      });
    };
    const isOnline = opts.isOnline || function () { return true; };
    let onChange = opts.onChange || function () {};

    let items = [];
    let ops = [];
    let meta = { lastServerAt: null, lastError: null, conflict: null };
    let undo = null;
    let chain = Promise.resolve();
    let loaded = false;

    function visible() {
      return items.filter(function (row) { return !row.deleted_at; })
        .slice()
        .sort(function (a, b) {
          const c = (a.category || "").localeCompare(b.category || "");
          if (c) return c;
          return (a.title || "").localeCompare(b.title || "");
        });
    }

    function status() {
      const pending = ops.length > 0;
      const online = !!isOnline();
      if (pending && !online) {
        return { state: "offline", pending: ops.length, label: "On this phone — not saved to the family list yet", lastServerAt: meta.lastServerAt };
      }
      if (pending && meta.lastError) {
        return { state: "error", pending: ops.length, label: "Couldn't save — will keep trying", lastServerAt: meta.lastServerAt };
      }
      if (pending) {
        return { state: "saving", pending: ops.length, label: "Saving…", lastServerAt: meta.lastServerAt };
      }
      if (!meta.lastServerAt) {
        return { state: "local", pending: 0, label: "Not saved yet", lastServerAt: null };
      }
      if (!online) {
        return { state: "offline", pending: 0, label: "Offline · last saved " + meta.lastServerAt, lastServerAt: meta.lastServerAt };
      }
      return { state: "saved", pending: 0, label: "Saved", lastServerAt: meta.lastServerAt };
    }

    async function persist() {
      await storage.set("packingItems", items);
      await storage.set("packingOps", ops);
      await storage.set("packingMeta", meta);
    }

    function emit() { onChange({ items: visible(), status: status(), conflict: meta.conflict }); }

    function rowIndex(id) { return items.findIndex(function (r) { return r.id === id; }); }

    function queueOp(row, baseVersion) {
      const existing = ops.find(function (op) { return op.itemId === row.id && op.state === "pending"; });
      if (existing) {
        existing.desired = desiredOf(row);
        return;
      }
      const inflight = ops.find(function (op) { return op.itemId === row.id && op.state === "inflight"; });
      if (inflight) {
        inflight.follow = desiredOf(row);
        return;
      }
      ops.push({
        opId: newId(),
        itemId: row.id,
        childId: row.child_id,
        baseVersion: baseVersion,
        desired: desiredOf(row),
        state: "pending"
      });
    }

    async function change(id, recipe, created) {
      const idx = rowIndex(id);
      const before = idx >= 0 ? clone(items[idx]) : null;
      const next = recipe(before ? clone(before) : null);
      if (!next) return;
      if (idx >= 0) items[idx] = next;
      else items.push(next);
      const base = before && before.version != null ? before.version : null;
      queueOp(next, created ? null : base);
      undo = { id: id, before: before, created: !!created };
      meta.lastError = null;
      await persist();
      emit();
      void flush();
    }

    async function undoLast() {
      const u = undo;
      undo = null;
      if (!u) return false;
      if (u.created && u.before == null) {
        const idx = rowIndex(u.id);
        const row = idx >= 0 ? items[idx] : null;
        if (row && row.version == null) {
          items.splice(idx, 1);
          ops = ops.filter(function (op) { return op.itemId !== u.id || op.state === "inflight"; });
          const inflight = ops.find(function (op) { return op.itemId === u.id && op.state === "inflight"; });
          if (inflight) inflight.follow = { title: row.title, qty: row.qty, category: row.category, checked: false, deleted: true, suggested: !!row.suggested };
        } else if (row) {
          row.deleted_at = now();
          queueOp(row, row.version);
        }
      } else if (u.before) {
        const idx = rowIndex(u.id);
        const current = idx >= 0 ? items[idx] : null;
        const restored = clone(u.before);
        if (current && current.version != null) {
          restored.version = current.version;
          restored.updated_at = current.updated_at;
        }
        if (idx >= 0) items[idx] = restored;
        else items.push(restored);
        queueOp(restored, restored.version == null ? null : restored.version);
      } else {
        const idx = rowIndex(u.id);
        if (idx >= 0) items.splice(idx, 1);
        ops = ops.filter(function (op) { return op.itemId !== u.id; });
      }
      await persist();
      emit();
      void flush();
      return true;
    }

    function applyServerRow(server) {
      if (!server) return;
      const idx = rowIndex(server.id);
      if (idx >= 0) items[idx] = clone(server);
      else items.push(clone(server));
    }

    async function flushOnce() {
      if (!isOnline()) {
        emit();
        return;
      }
      for (let guard = 0; guard < 40; guard++) {
        const op = ops.find(function (o) { return o.state === "pending"; }) || ops.find(function (o) { return o.state === "inflight"; });
        if (!op) break;
        op.state = "inflight";
        await persist();
        emit();
        let res;
        try {
          res = await transport.apply(clone(op));
        } catch (err) {
          op.state = "pending";
          meta.lastError = (err && err.message) || "network";
          await persist();
          emit();
          return;
        }
        meta.lastError = null;
        meta.lastServerAt = now();
        const statusName = res && res.status;
        if (statusName === "conflict") {
          ops = ops.filter(function (o) { return o.itemId !== op.itemId; });
          if (res.item) applyServerRow(res.item);
          else items = items.filter(function (r) { return r.id !== op.itemId; });
          meta.conflict = { itemId: op.itemId, at: now() };
          undo = null;
        } else if (statusName === "applied" || statusName === "duplicate") {
          const follow = op.follow;
          ops = ops.filter(function (o) { return o.opId !== op.opId; });
          if (res.item) applyServerRow(res.item);
          else if (op.desired && op.desired.deleted) {
            const idx = rowIndex(op.itemId);
            if (idx >= 0 && !items[idx].version) items.splice(idx, 1);
            else if (idx >= 0) items[idx].deleted_at = items[idx].deleted_at || now();
          }
          const local = items.find(function (r) { return r.id === op.itemId; });
          if (follow && local) {
            local.title = follow.title;
            local.qty = follow.qty;
            local.category = follow.category;
            local.checked = follow.checked;
            local.suggested = follow.suggested;
            local.deleted_at = follow.deleted ? (local.deleted_at || now()) : null;
            ops.push({
              opId: newId(),
              itemId: local.id,
              childId: local.child_id,
              baseVersion: local.version,
              desired: desiredOf(local),
              state: "pending"
            });
          } else if (local && res.item && !sameDesired(local, desiredOf(res.item)) && !ops.some(function (o) { return o.itemId === local.id; })) {
            ops.push({
              opId: newId(),
              itemId: local.id,
              childId: local.child_id,
              baseVersion: res.item.version,
              desired: desiredOf(local),
              state: "pending"
            });
          }
        } else {
          op.state = "pending";
          meta.lastError = "unexpected";
          await persist();
          emit();
          return;
        }
        await persist();
        emit();
      }
    }

    function flush() {
      const run = chain.then(flushOnce, flushOnce);
      chain = run.then(function () {}, function () {});
      return run;
    }

    async function load(pullRows) {
      items = (await storage.get("packingItems")) || [];
      ops = (await storage.get("packingOps")) || [];
      meta = (await storage.get("packingMeta")) || { lastServerAt: null, lastError: null, conflict: null };
      ops.forEach(function (op) { if (op.state === "inflight") op.state = "pending"; });
      loaded = true;
      if (pullRows && isOnline()) {
        try {
          const remote = await transport.pull();
          const dirtyIds = {};
          ops.forEach(function (op) { dirtyIds[op.itemId] = true; });
          remote.forEach(function (row) {
            if (!dirtyIds[row.id]) applyServerRow(row);
          });
          const remoteIds = {};
          remote.forEach(function (row) { remoteIds[row.id] = true; });
          items = items.filter(function (row) {
            if (dirtyIds[row.id]) return true;
            if (row.version == null) return true;
            return !!remoteIds[row.id];
          });
          meta.lastServerAt = now();
          meta.lastError = null;
          await persist();
        } catch (err) {
          meta.lastError = (err && err.message) || "network";
        }
      }
      emit();
      if (ops.length) await flush();
    }

    function noteRemote(row) {
      if (!row || !row.id) return;
      const dirty = ops.some(function (op) { return op.itemId === row.id; });
      if (dirty) return;
      const local = items.find(function (r) { return r.id === row.id; });
      if (local && local.updated_at && row.updated_at && row.updated_at < local.updated_at) return;
      applyServerRow(row);
      meta.lastServerAt = meta.lastServerAt || now();
      void persist().then(emit);
    }

    return {
      load: load,
      flush: flush,
      items: function () { return visible(); },
      allItems: function () { return clone(items); },
      ops: function () { return clone(ops); },
      status: status,
      loaded: function () { return loaded; },
      takeConflict: function () {
        const c = meta.conflict;
        meta.conflict = null;
        return c;
      },
      noteRemote: noteRemote,
      setOnlineRefresh: function () { return flush(); },
      add: function (childId, fields) {
        const row = {
          id: newId(),
          child_id: childId,
          title: (fields.title || "").trim(),
          qty: fields.qty == null || fields.qty === "" ? null : Number(fields.qty),
          category: fields.category || null,
          checked: false,
          deleted_at: null,
          suggested: false,
          version: null,
          updated_at: null
        };
        return change(row.id, function () { return row; }, true);
      },
      edit: function (id, fields) {
        return change(id, function (row) {
          if (!row) return null;
          if (fields.title != null) row.title = String(fields.title).trim();
          if ("qty" in fields) row.qty = fields.qty == null || fields.qty === "" ? null : Number(fields.qty);
          if ("category" in fields) row.category = fields.category || null;
          return row;
        });
      },
      toggle: function (id) {
        return change(id, function (row) {
          if (!row) return null;
          row.checked = !row.checked;
          return row;
        });
      },
      remove: function (id) {
        return change(id, function (row) {
          if (!row) return null;
          row.deleted_at = now();
          return row;
        });
      },
      undo: undoLast
    };
  }

  function createItineraryCache(storage) {
    return {
      async save(rows, syncedAt) {
        await storage.set("itinerarySnapshot", { rows: rows, syncedAt: syncedAt });
      },
      async load() {
        return (await storage.get("itinerarySnapshot")) || null;
      }
    };
  }

  /* Reference server used by tests. Mirrors private.apply_packing_op. */
  function createMemoryServer() {
    const rows = new Map();
    const seen = new Map();
    let clock = 0;
    function stamp() {
      clock += 1;
      return "2026-01-01T00:00:" + String(clock).padStart(2, "0") + ".000Z";
    }
    function resultFor(opId) { return seen.get(opId); }
    return {
      rows: rows,
      async apply(op) {
        if (seen.has(op.opId)) return clone(seen.get(op.opId));
        const current = rows.get(op.itemId);
        let result;
        if (!current) {
          if (op.desired.deleted) result = { status: "applied", item: null };
          else if (op.baseVersion != null) result = { status: "conflict", item: null };
          else {
            const item = {
              id: op.itemId,
              child_id: op.childId,
              title: op.desired.title,
              qty: op.desired.qty,
              category: op.desired.category,
              checked: !!op.desired.checked,
              deleted_at: null,
              suggested: !!op.desired.suggested,
              version: 1,
              updated_at: stamp()
            };
            rows.set(op.itemId, item);
            result = { status: "applied", item: clone(item) };
          }
        } else if (op.baseVersion !== current.version) {
          result = { status: "conflict", item: clone(current) };
        } else {
          const item = clone(current);
          item.title = op.desired.title;
          item.qty = op.desired.qty;
          item.category = op.desired.category;
          item.checked = !!op.desired.checked;
          item.suggested = !!op.desired.suggested;
          item.deleted_at = op.desired.deleted ? (item.deleted_at || stamp()) : null;
          item.version = current.version + 1;
          item.updated_at = stamp();
          rows.set(op.itemId, item);
          result = { status: "applied", item: clone(item) };
        }
        seen.set(op.opId, result);
        return clone(result);
      },
      async pull() {
        return Array.from(rows.values()).map(clone);
      },
      peek: function (id) { return clone(rows.get(id)); }
    };
  }

  return {
    clone: clone,
    memoryStorage: memoryStorage,
    idbStorage: idbStorage,
    createPackingSync: createPackingSync,
    createItineraryCache: createItineraryCache,
    createMemoryServer: createMemoryServer,
    desiredOf: desiredOf
  };
});
