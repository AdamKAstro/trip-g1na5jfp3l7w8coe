/* Child share links. The token lives in the URL fragment, never the query string. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  if (root) root.TripKidsLink = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function parseKidHash(hash) {
    const m = /^#k=([A-Za-z0-9_-]{43,128})$/.exec(String(hash || ""));
    return m ? m[1] : "";
  }

  function shareUrl(token, pageUrl) {
    const u = new URL(pageUrl || "https://adamkastro.github.io/trip-g1na5jfp3l7w8coe/");
    u.searchParams.delete("k");
    u.hash = "k=" + token;
    return u.toString();
  }

  function stripKidHash(pageUrl) {
    const u = new URL(pageUrl);
    if (String(u.hash || "").indexOf("#k=") === 0) u.hash = "";
    return u.toString();
  }

  function takeFromLocation(loc) {
    const token = parseKidHash(loc && loc.hash);
    if (!token || !loc) return "";
    const next = loc.pathname + loc.search;
    if (typeof history !== "undefined" && history.replaceState) history.replaceState(null, "", next);
    return token;
  }

  async function redeem(sb, token) {
    const fail = "This link doesn't work any more. Ask Mum or Dad to share a new one.";
    if (!parseKidHash("#k=" + token)) return { ok: false, message: fail };
    const { data, error } = await sb.rpc("redeem_child_link", { p_token: token });
    if (error || !data || data.error || !data.email) return { ok: false, message: fail };
    const signed = await sb.auth.signInWithPassword({ email: data.email, password: token });
    if (!signed || signed.error) return { ok: false, message: fail };
    return { ok: true, email: data.email, displayName: data.display_name || "" };
  }

  return {
    parseKidHash: parseKidHash,
    shareUrl: shareUrl,
    stripKidHash: stripKidHash,
    takeFromLocation: takeFromLocation,
    redeem: redeem
  };
});
