/* Kids and parent packing/itinerary UI. Itinerary is read-only for kids.
   Packing edits go through TripSync so a local change is not called "Saved". */
(function () {
  "use strict";
  const seed = window.TripSeed;
  const syncLib = window.TripSync;
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const MONTHS = ["", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const CATS = ["Clothes", "Warm", "Snow", "Sun", "Toiletries", "Electronics", "Bags", "Documents", "Other"];
  const state = {
    mode: null,
    sb: null,
    me: null,
    preview: false,
    online: true,
    tab: "itin",
    childId: null,
    childName: "",
    activeChild: seed.CHILDREN[0].id,
    stops: [],
    dbClimate: null,
    itinLabel: "",
    sync: null,
    channel: null,
    editing: null,
    server: null
  };

  function previewMode() {
    const host = location.hostname;
    if (host !== "localhost" && host !== "127.0.0.1") return null;
    return new URLSearchParams(location.search).get("preview");
  }
  function fmtDay(iso) {
    const [y, m, d] = iso.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  }
  function fmtRange(a, b) {
    if (!b || a === b) return fmtDay(a);
    return fmtDay(a) + " – " + fmtDay(b);
  }
  function fmtWhen(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString("en-AU", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
  }
  function childById(id) {
    return seed.CHILDREN.find((c) => c.id === id) || seed.CHILDREN[0];
  }
  function online() { return state.online && (state.preview || navigator.onLine); }

  function snack(text, undo) {
    const bar = $("#kSnack");
    if (!bar) return;
    $("#kSnackTxt").textContent = text;
    $("#kUndo").classList.toggle("hidden", !undo);
    bar.classList.add("show");
    document.body.classList.add("k-snacking");
    clearTimeout(snack._t);
    snack._t = setTimeout(() => { bar.classList.remove("show"); document.body.classList.remove("k-snacking"); }, undo ? 5000 : 3200);
    snack._undo = undo || null;
  }

  function mapStop(row) {
    return {
      id: row.id,
      startsOn: row.starts_on || row.startsOn,
      endsOn: row.ends_on || row.endsOn,
      title: row.title,
      summary: row.summary,
      placeKey: row.place_key || row.placeKey,
      sort: row.sort
    };
  }

  function mapClimate(row) {
    return {
      placeKey: row.place_key,
      month: row.month,
      available: true,
      highC: row.high_c,
      lowC: row.low_c,
      sourceHigh: row.source_high,
      sourceLow: row.source_low,
      period: row.period,
      station: row.station,
      sourceName: row.source_name,
      sourceUrl: row.source_url,
      sourceDataUrl: row.source_data_url,
      kind: row.kind,
      note: row.note
    };
  }

  function statusHtml() {
    const st = state.sync ? state.sync.status() : { state: "local", label: "Not saved yet" };
    const cls = st.state === "saved" ? "ok" : st.state === "error" ? "bad" : st.state === "saving" ? "wait" : "off";
    return `<p class="k-status k-${cls}" role="status">${esc(st.label)}</p>`;
  }

  function climateBlock(presented) {
    const bits = presented.climate.map((row) => {
      if (!row.available) {
        return `<p class="k-wx-miss">Typical temperature unavailable</p><p class="k-why">${esc(row.reason || "No reliable average for this stop.")}</p>`;
      }
      const links = [`<a href="${esc(row.sourceUrl)}" target="_blank" rel="noopener">${esc(row.sourceName)}</a>`];
      if (row.sourceDataUrl) links.push(`<a href="${esc(row.sourceDataUrl)}" target="_blank" rel="noopener">Station numbers</a>`);
      return `<p class="k-wx-num"><span>${esc(MONTHS[row.month] || "")}</span> Day about ${row.highC}° <b>night about ${row.lowC}°</b></p>
        <details class="k-src"><summary>Where this average comes from</summary>
          <p>${esc(row.kind)}. ${esc(row.station)}. Period ${esc(row.period)}. Source figures ${esc(row.sourceHigh)} / ${esc(row.sourceLow)}, shown here to the nearest degree.</p>
          <p>${esc(row.note)}</p>
          <p class="k-links">${links.join(" · ")}</p>
        </details>`;
    }).join("");
    const tip = presented.tip ? `<p class="k-tip">${esc(presented.tip)}</p>` : "";
    return `<div class="k-wx"><p class="k-kicker">Seasonal average · not a forecast</p>${bits}${tip}</div>`;
  }

  function itineraryHtml() {
    if (!state.stops.length) {
      const setup = state.mode === "parent"
        ? "Add a day below. If you expected the starter plan, the kids database update still needs to be applied. Don’t paste booking codes, prices or passport details — kids can read every word."
        : "The day-by-day plan isn’t on this phone yet. Ask Mum or Dad to add it. Your packing list still works, and nothing here is a booking.";
      return `<section class="k-empty"><div class="big" aria-hidden="true">🗺️</div><b>No itinerary yet</b><p>${esc(setup)}</p><p class="k-itin-meta">${esc(state.itinLabel)}</p></section>` + (state.mode === "parent" ? editorHtml(null) : "");
    }
    const stops = state.stops.slice().sort((a, b) => a.sort - b.sort || a.startsOn.localeCompare(b.startsOn));
    let cruiseNoted = false;
    const cards = stops.map((stop) => {
      const presented = seed.presentStop(stop, state.dbClimate);
      let note = "";
      if (!cruiseNoted && ["cocoa", "sea", "costa-maya", "roatan", "cozumel", "cococay"].includes(stop.placeKey) && stop.startsOn >= "2027-01-03") {
        cruiseNoted = true;
        note = `<aside class="k-note"><b>Cruise days</b><p>${esc(seed.CRUISE_NOTE)}</p><p class="k-links">${seed.CRUISE_SOURCES.map((s) => `<a href="${esc(s.url)}" target="_blank" rel="noopener">${esc(s.name)}</a>`).join(" · ")}</p></aside>`;
      }
      const tools = state.mode === "parent" ? `<div class="k-tools"><button type="button" class="srow" data-edit-stop="${esc(stop.id)}">Edit this day</button></div>` : "";
      return `${note}<article class="k-day">
        <p class="k-when">${esc(fmtRange(stop.startsOn, stop.endsOn))}</p>
        <h3>${esc(stop.title)}</h3>
        ${stop.summary ? `<p class="k-sum">${esc(stop.summary)}</p>` : ""}
        ${climateBlock(presented)}
        ${tools}
      </article>`;
    }).join("");
    const add = state.mode === "parent" ? `<button type="button" class="btn k-addday" id="kAddDay">Add a day</button>` : "";
    return `<p class="k-plan">${esc(seed.PLAN_NOTE)}</p><p class="k-itin-meta">${esc(state.itinLabel)}</p>${cards}${add}`;
  }

  function editorHtml(stop) {
    const s = stop || { startsOn: "", endsOn: "", title: "", summary: "", placeKey: "", id: "" };
    const opts = ['<option value="">No temperature place</option>'].concat(
      ["singapore", "nyc", "vermont", "dc", "miami", "vero", "cocoa", "orlando", "costa-maya", "roatan", "cozumel", "cococay", "sea", "travel"].map((k) => `<option value="${k}" ${s.placeKey === k ? "selected" : ""}>${k}</option>`)
    ).join("");
    return `<form class="k-form" id="kDayForm" data-id="${esc(s.id || "")}">
      <h3>${s.id ? "Edit day" : "Add a day"}</h3>
      <label>Starts <input name="starts" type="date" required value="${esc(s.startsOn || "")}"></label>
      <label>Ends <input name="ends" type="date" value="${esc(s.endsOn || "")}"></label>
      <label>Title <input name="title" maxlength="140" required value="${esc(s.title || "")}"></label>
      <label>One line for the kids <input name="summary" maxlength="400" value="${esc(s.summary || "")}"></label>
      <label>Place for the temperature <select name="place">${opts}</select></label>
      <p class="k-why">Temperatures stay next to the day. Saving a day does not change the climate numbers.</p>
      <div class="cs-btns"><button type="button" class="btn ghost" id="kDayCancel">Cancel</button><button class="btn" type="submit">Save day</button></div>
      ${s.id ? `<button type="button" class="srow danger" id="kDayDelete">Delete this day</button>` : ""}
    </form>`;
  }

  function packingHtml() {
    const childId = state.mode === "child" ? state.childId : state.activeChild;
    const rows = (state.sync ? state.sync.items() : []).filter((r) => r.child_id === childId);
    const done = rows.filter((r) => r.checked).length;
    const groups = {};
    rows.forEach((r) => {
      const g = r.category || "Other";
      (groups[g] = groups[g] || []).push(r);
    });
    const order = CATS.filter((c) => groups[c]).concat(Object.keys(groups).filter((g) => !CATS.includes(g)));
    let body;
    if (!rows.length) {
      body = `<div class="k-empty"><div class="big" aria-hidden="true">🧳</div><b>Nothing to pack yet</b><p>${state.preview ? "Preview list is empty." : "The starter ideas show up after the database update, or add your own."}</p></div>`;
    } else {
      body = order.map((g) => `<section class="k-sec"><h3>${esc(g)}</h3>${groups[g].map(packRow).join("")}</section>`).join("");
    }
    const who = state.mode === "parent" ? `<div class="k-who" role="tablist">${seed.CHILDREN.map((c) => `<button type="button" data-child="${c.id}" aria-pressed="${c.id === childId}">${esc(c.displayName)}</button>`).join("")}</div>` : "";
    const invite = state.mode === "parent" && !state.preview ? `<button type="button" class="btn ghost" id="kInviteBtn">Set up ${esc(childById(childId).displayName)}’s phone</button><div id="kInviteOut"></div>` : "";
    return `${who}<p class="k-count">${done} of ${rows.length} packed</p>
      <p class="k-plan">Starter ideas — change, add or cross out anything. Nothing here is booked.</p>
      ${statusHtml()}${invite}${body}
      <button type="button" class="btn k-addday" id="kAddItem">Add an item</button>`;
  }

  function packRow(r) {
    const qty = r.qty ? `<span class="pill">${esc(String(r.qty))}</span>` : "";
    const idea = r.suggested ? `<span class="pill">Idea</span>` : "";
    return `<article class="k-pack ${r.checked ? "done" : ""}">
      <button type="button" class="tick" data-toggle="${esc(r.id)}" role="checkbox" aria-checked="${r.checked}" aria-label="${r.checked ? "Packed" : "Not packed"}: ${esc(r.title)}"><span class="box"><svg viewBox="0 0 24 24" width="18" height="18"><path d="M5 12.5l4.2 4.2L19 7" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg></span></button>
      <button type="button" class="k-open" data-open="${esc(r.id)}"><span class="k-title">${esc(r.title)}</span><span class="meta">${qty}${idea}</span></button>
    </article>`;
  }

  function render() {
    const root = state.mode === "child" ? $("#kMain") : $("#kParentBody");
    if (!root) return;
    const hello = $("#kHello");
    if (hello && state.mode === "child") hello.textContent = state.childName ? "Hi " + state.childName : "Our trip";
    const syncEl = $("#kSync");
    if (syncEl && state.mode === "child") {
      syncEl.textContent = state.tab === "pack" && state.sync ? state.sync.status().label : (state.itinLabel || "Itinerary");
    }
    if (state.tab === "pack") root.innerHTML = packingHtml();
    else root.innerHTML = itineraryHtml();
    const add = $("#kAdd");
    if (add) add.classList.toggle("hidden", !(state.mode === "child" && state.tab === "pack"));
    document.querySelectorAll("[data-ktab]").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.ktab === state.tab)));
    const conflict = state.sync && state.sync.takeConflict && state.sync.takeConflict();
    if (conflict) snack("Kept the newer change from the other phone");
  }

  function setTab(tab) {
    state.tab = tab === "pack" ? "pack" : "itin";
    try { localStorage.setItem("kidsTab", state.tab); } catch (e) {}
    render();
  }

  async function refreshItinerary() {
    if (state.preview) {
      state.stops = seed.ITINERARY.map(mapStop);
      state.dbClimate = null;
      state.itinLabel = "Preview on this computer — not the live family list";
      render();
      return;
    }
    const cache = syncLib.createItineraryCache(syncLib.idbStorage("usa-trip-kids"));
    try {
      const [itin, climate] = await Promise.all([
        state.sb.from("trip_itinerary").select("id,starts_on,ends_on,title,summary,place_key,sort").order("sort"),
        state.sb.from("climate_normals").select("*")
      ]);
      if (itin.error) throw itin.error;
      state.stops = (itin.data || []).map(mapStop);
      state.dbClimate = climate.error ? null : (climate.data || []).map(mapClimate);
      const syncedAt = new Date().toISOString();
      await cache.save(state.stops, syncedAt);
      state.itinLabel = "Last synced " + fmtWhen(syncedAt);
    } catch (err) {
      const snap = await cache.load();
      if (snap && snap.rows && snap.rows.length) {
        state.stops = snap.rows;
        state.dbClimate = null;
        state.itinLabel = "Offline · itinerary last synced " + fmtWhen(snap.syncedAt);
      } else {
        state.stops = [];
        state.dbClimate = null;
        state.itinLabel = "Itinerary isn’t on this phone yet";
      }
    }
    render();
  }

  function transport() {
    if (state.preview) return state.server;
    return {
      async apply(op) {
        const { data, error } = await state.sb.rpc("apply_packing_op", {
          p_op_id: op.opId,
          p_item_id: op.itemId,
          p_child_id: op.childId,
          p_base_version: op.baseVersion,
          p_title: op.desired.title,
          p_qty: op.desired.qty,
          p_category: op.desired.category,
          p_checked: op.desired.checked,
          p_deleted: op.desired.deleted,
          p_suggested: op.desired.suggested
        });
        if (error) throw error;
        return data;
      },
      async pull() {
        const { data, error } = await state.sb.from("packing_items").select("*");
        if (error) throw error;
        return data || [];
      }
    };
  }

  async function ensureSync() {
    if (state.sync) return;
    const storage = state.preview ? syncLib.memoryStorage() : syncLib.idbStorage("usa-trip-kids");
    state.sync = syncLib.createPackingSync({
      storage: storage,
      transport: transport(),
      isOnline: online,
      onChange: function () { render(); }
    });
    await state.sync.load(true);
  }

  function subscribe() {
    if (state.preview || !state.sb || state.channel) return;
    state.channel = state.sb.channel("kids-live")
      .on("postgres_changes", { event: "*", schema: "public", table: "packing_items" }, (payload) => {
        if (payload.new && payload.new.id && state.sync) state.sync.noteRemote(payload.new);
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "trip_itinerary" }, () => { refreshItinerary(); })
      .subscribe((s) => {
        const dot = $("#kLive");
        if (dot) dot.classList.toggle("on", s === "SUBSCRIBED");
      });
  }

  async function mountChild(sb, user) {
    state.mode = "child";
    state.sb = sb;
    state.me = user;
    state.preview = false;
    state.childId = user.app_metadata && user.app_metadata.child_id;
    state.childName = (user.app_metadata && user.app_metadata.child_slug) || "";
    try {
      const { data } = await sb.rpc("my_access");
      if (data && data.display_name) state.childName = data.display_name;
      if (data && data.child_id) state.childId = data.child_id;
    } catch (e) {}
    const app = $("#kidsApp");
    if (app) app.classList.remove("hidden");
    try { state.tab = localStorage.getItem("kidsTab") === "pack" ? "pack" : "itin"; } catch (e) { state.tab = "itin"; }
    await ensureSync();
    subscribe();
    await refreshItinerary();
  }

  function unmountChild() {
    if (state.mode === "child") {
      state.mode = null;
      const app = $("#kidsApp");
      if (app) app.classList.add("hidden");
    }
  }
  function disconnect() {
    if (state.channel && state.sb && state.sb.removeChannel) state.sb.removeChannel(state.channel);
    state.channel = null;
    state.sync = null;
    state.mode = null;
    state.stops = [];
    const app = $("#kidsApp");
    if (app) app.classList.add("hidden");
  }

  async function mountPreview(kind) {
    state.preview = true;
    state.online = true;
    state.mode = kind === "parent" ? "parent" : "child";
    state.childId = seed.CHILDREN[0].id;
    state.childName = "Liam";
    state.activeChild = seed.CHILDREN[0].id;
    state.server = syncLib.createMemoryServer();
    for (const child of seed.CHILDREN) {
      for (const item of seed.PACKING) {
        const id = seed.packingId(child.sort, item.n);
        await state.server.apply({
          opId: id,
          itemId: id,
          childId: child.id,
          baseVersion: null,
          desired: { title: item.title, qty: null, category: item.category, checked: false, deleted: false, suggested: true }
        });
      }
    }
    if (state.mode === "child") {
      const app = $("#kidsApp");
      if (app) app.classList.remove("hidden");
      $("#app") && $("#app").classList.add("hidden");
      const tools = $("#kPreviewTools");
      if (tools) tools.classList.remove("hidden");
    }
    await ensureSync();
    await refreshItinerary();
  }

  async function renderParent(list, ctx) {
    if (!list) return;
    if (list.dataset.kidsMounted === "1" && state.mode === "parent" && $("#kParentBody")) return;
    state.mode = "parent";
    state.sb = ctx.sb;
    state.me = ctx.me;
    state.preview = !!ctx.preview;
    list.dataset.kidsMounted = "1";
    list.innerHTML = `<section class="k-wrap"><div class="k-hero"><h2>Kids phones</h2><p>Itinerary first, packing second. Kids cannot open the to-do list, booking codes, suggestions or your notes.</p></div><div class="kseg" role="tablist"><button type="button" data-ktab="itin" aria-selected="true">Itinerary</button><button type="button" data-ktab="pack" aria-selected="false">Packing</button></div><div id="kParentSync"></div><div id="kParentBody"></div>${state.preview ? `<details class="k-src"><summary>Preview tools</summary><button type="button" class="k-preview-off">Simulate offline</button></details>` : ""}</section>`;
    if (state.preview) await mountPreview("parent");
    else {
      await ensureSync();
      subscribe();
      await refreshItinerary();
    }
  }

  function openEditor(row) {
    state.editing = row;
    const dlg = $("#kEdit");
    if (!dlg) return;
    $("#kEditTitle").textContent = row ? "Edit item" : "Add item";
    $("#kItemTitle").value = row ? row.title : "";
    $("#kItemQty").value = row && row.qty ? String(row.qty) : "";
    const cat = row && row.category;
    $("#kCats").innerHTML = CATS.map((c) => `<button type="button" class="chip" data-cat="${esc(c)}" aria-pressed="${c === cat}">${esc(c)}</button>`).join("");
    $("#kDeleteItem").classList.toggle("hidden", !row);
    state.editingCat = cat || "";
    if (typeof dlg.showModal === "function") dlg.showModal();
  }

  async function saveItem(ev) {
    ev.preventDefault();
    const title = $("#kItemTitle").value.trim();
    if (!title) { $("#kEditErr").textContent = "Add a name first."; return; }
    const qtyRaw = $("#kItemQty").value.trim();
    const qty = qtyRaw === "" ? null : Number(qtyRaw);
    if (qty != null && (!Number.isInteger(qty) || qty < 1 || qty > 99)) { $("#kEditErr").textContent = "Quantity should be 1–99, or empty."; return; }
    const childId = state.mode === "child" ? state.childId : state.activeChild;
    $("#kEditErr").textContent = "";
    if (state.editing) await state.sync.edit(state.editing.id, { title: title, qty: qty, category: state.editingCat || null });
    else await state.sync.add(childId, { title: title, qty: qty, category: state.editingCat || null });
    $("#kEdit").close();
    snack(state.editing ? "Updated" : "Added", true);
    state.editing = null;
  }

  async function saveDay(form) {
    const data = new FormData(form);
    const row = {
      id: form.dataset.id || (crypto.randomUUID ? crypto.randomUUID() : String(Date.now())),
      starts_on: data.get("starts"),
      ends_on: data.get("ends") || data.get("starts"),
      title: String(data.get("title") || "").trim(),
      summary: String(data.get("summary") || "").trim() || null,
      place_key: data.get("place") || null,
      sort: 500
    };
    if (!row.title || !row.starts_on) return;
    if (state.preview) {
      const existing = state.stops.find((s) => s.id === row.id);
      const mapped = mapStop(row);
      if (existing) Object.assign(existing, mapped);
      else state.stops.push(mapped);
      state.itinLabel = "Preview edit — not saved to the family server";
      render();
      return;
    }
    const { error } = await state.sb.from("trip_itinerary").upsert(row);
    if (error) { snack("Couldn't save that day"); return; }
    snack("Day saved");
    await refreshItinerary();
  }

  async function makeInvite() {
    const child = childById(state.activeChild);
    const out = $("#kInviteOut");
    if (!state.sb) { if (out) out.textContent = "Sign in as Mum or Dad on the live site after the database update."; return; }
    if (out) out.textContent = "Making a code…";
    const { data, error } = await state.sb.rpc("create_child_invite", { p_slug: child.slug });
    if (error || !data) { if (out) out.textContent = "Couldn't make a code. Apply the kids database update first, and use a parent sign-in."; return; }
    out.innerHTML = `<div class="k-code"><p><b>${esc(child.displayName)}</b> · works once, for 7 days</p><p class="k-code-val">${esc(data.code)}</p><p>On their phone: Kids — invite code. Then this email next time: ${esc(data.email)}</p><button type="button" class="btn" id="kCopyCode">Copy code</button></div>`;
    $("#kCopyCode").onclick = () => navigator.clipboard?.writeText(data.code).then(() => snack("Code copied"), () => snack("Couldn't copy"));
  }

  function safeInviteError(message) {
    const known = ["That code is not valid", "That code has expired", "That code has already been used", "Choose a password of 8 to 72 characters", "Sign-ups are closed", "Too many attempts. Wait a few minutes and try again."];
    return known.indexOf(message) >= 0 ? message : "Couldn't set up this phone. Ask Mum or Dad for a new code.";
  }

  async function claimInvite(ev) {
    ev.preventDefault();
    const code = $("#kCodeIn").value;
    const pass = $("#kPass").value;
    const again = $("#kPass2").value;
    const err = $("#kInviteErr");
    err.textContent = "";
    if (pass !== again) { err.textContent = "Those passwords don't match."; return; }
    if (pass.length < 8) { err.textContent = "Choose a password of 8 to 72 characters"; return; }
    const btn = $("#kInviteGo");
    btn.disabled = true;
    try {
      const live = state.sb;
      if (!live) { err.textContent = "The sign-in service isn't ready."; return; }
      const { data, error } = await live.rpc("claim_child_invite", { p_code: code, p_password: pass });
      if (error) { err.textContent = safeInviteError(error.message); return; }
      if (!data || data.error) { err.textContent = safeInviteError(data && data.error); return; }
      const signed = await live.auth.signInWithPassword({ email: data.email, password: pass });
      if (signed.error) { err.textContent = "The phone is set up, but sign-in failed. Ask for a new code."; return; }
      $("#kInvite").close();
    } finally {
      btn.disabled = false;
    }
  }

  function bind() {
    document.addEventListener("click", async (ev) => {
      const tab = ev.target.closest("[data-ktab]");
      if (tab) { setTab(tab.dataset.ktab); return; }
      const child = ev.target.closest("[data-child]");
      if (child) { state.activeChild = child.dataset.child; render(); return; }
      const toggle = ev.target.closest("[data-toggle]");
      if (toggle && state.sync) {
        await state.sync.toggle(toggle.dataset.toggle);
        snack(state.sync.items().some((r) => r.id === toggle.dataset.toggle && r.checked) ? "Packed" : "Unpacked", true);
        return;
      }
      const open = ev.target.closest("[data-open]");
      if (open && state.sync) {
        const row = state.sync.allItems().find((r) => r.id === open.dataset.open);
        openEditor(row);
        return;
      }
      if (ev.target.closest("#kAdd") || ev.target.closest("#kAddItem")) { openEditor(null); return; }
      const editStop = ev.target.closest("[data-edit-stop]");
      if (editStop) {
        const stop = state.stops.find((s) => s.id === editStop.dataset.editStop);
        const root = state.mode === "child" ? $("#kMain") : $("#kParentBody");
        if (root && stop) root.insertAdjacentHTML("beforeend", editorHtml(stop));
        return;
      }
      if (ev.target.closest("#kAddDay")) {
        const root = $("#kParentBody");
        if (root) root.insertAdjacentHTML("beforeend", editorHtml(null));
        return;
      }
      if (ev.target.closest("#kDayCancel")) { render(); return; }
      if (ev.target.closest("#kDayDelete")) {
        const form = $("#kDayForm");
        const id = form && form.dataset.id;
        if (state.preview) { state.stops = state.stops.filter((s) => s.id !== id); render(); return; }
        const { error } = await state.sb.from("trip_itinerary").delete().eq("id", id);
        if (error) snack("Couldn't delete that day");
        else { snack("Day removed"); await refreshItinerary(); }
        return;
      }
      if (ev.target.closest("#kInviteBtn")) { makeInvite(); return; }
      if (ev.target.closest(".k-preview-off")) {
        state.online = !state.online;
        snack(state.online ? "Preview is back online" : "Preview is offline");
        if (state.sync) await state.sync.flush();
        render();
        return;
      }
      const cat = ev.target.closest("#kCats [data-cat]");
      if (cat) {
        state.editingCat = state.editingCat === cat.dataset.cat ? "" : cat.dataset.cat;
        document.querySelectorAll("#kCats [data-cat]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.cat === state.editingCat)));
      }
    });
    document.addEventListener("submit", (ev) => {
      if (ev.target.id === "kDayForm") { ev.preventDefault(); saveDay(ev.target); }
      if (ev.target.id === "kItemForm") saveItem(ev);
      if (ev.target.id === "kInviteForm") claimInvite(ev);
    });
    const undo = $("#kUndo");
    if (undo) undo.onclick = async () => {
      $("#kSnack").classList.remove("show");
      if (state.sync) await state.sync.undo();
    };
    const entry = $("#kidEntry");
    if (entry) entry.onclick = () => { $("#kInviteErr").textContent = ""; $("#kInvite").showModal(); };
    const cancel = $("#kInviteCancel");
    if (cancel) cancel.onclick = () => $("#kInvite").close();
    const del = $("#kDeleteItem");
    if (del) del.onclick = async () => {
      if (!state.editing) return;
      const id = state.editing.id;
      $("#kEdit").close();
      await state.sync.remove(id);
      snack("Deleted", true);
      state.editing = null;
    };
    const out = $("#kOut");
    if (out) out.onclick = async () => { if (state.sb) await state.sb.auth.signOut(); };
    const reload = $("#kReload");
    if (reload) reload.onclick = () => { refreshItinerary(); if (state.sync) state.sync.flush(); };
    window.addEventListener("online", () => { if (state.sync) state.sync.flush(); render(); });
    window.addEventListener("offline", () => render());
  }

  let bound = false;
  function init(client) {
    state.sb = client || state.sb;
    if (bound) return;
    bound = true;
    bind();
  }

  window.TripKidsUI = {
    init: init,
    mountChild: mountChild,
    unmountChild: unmountChild,
    disconnect: disconnect,
    renderParent: renderParent,
    mountPreview: mountPreview,
    onVisible: function () { refreshItinerary(); if (state.sync) state.sync.flush(); },
    setClient: function (client) { state.sb = client; }
  };
})();
