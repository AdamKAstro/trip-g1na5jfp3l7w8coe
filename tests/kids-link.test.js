"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const link = require("../kids-link.js");

const token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR";

test("a share link keeps the token in the fragment and out of the query", function () {
  const url = link.shareUrl(token, "https://adamkastro.github.io/trip-g1na5jfp3l7w8coe/?from=home");
  const u = new URL(url);
  assert.equal(u.searchParams.get("k"), null);
  assert.equal(u.hash, "#k=" + token);
  assert.equal(link.parseKidHash(u.hash), token);
  assert.equal(link.parseKidHash(""), "");
  assert.equal(link.parseKidHash("#k=short"), "");
  assert.equal(link.parseKidHash("#k=" + token + ".bad"), "");
});

test("stripping the fragment leaves the rest of the address", function () {
  const raw = "https://adamkastro.github.io/trip-g1na5jfp3l7w8coe/index.html?x=1#k=" + token;
  assert.equal(link.stripKidHash(raw), "https://adamkastro.github.io/trip-g1na5jfp3l7w8coe/index.html?x=1");
});

test("redeem signs in with the token as the password and stops when the link is cancelled", async function () {
  const calls = [];
  const sb = {
    rpc: async function (_name, args) {
      calls.push(args.p_token);
      if (args.p_token === token) return { data: { email: "liam@kids.usa-trip.invalid", display_name: "Liam" }, error: null };
      return { data: { error: "This link doesn't work any more. Ask Mum or Dad to share a new one." }, error: null };
    },
    auth: {
      signInWithPassword: async function (body) {
        calls.push(body);
        return { error: null };
      }
    }
  };
  const ok = await link.redeem(sb, token);
  assert.equal(ok.ok, true);
  assert.equal(ok.email, "liam@kids.usa-trip.invalid");
  assert.equal(calls[1].password, token);
  assert.equal(calls[1].email, "liam@kids.usa-trip.invalid");
  const cancelled = await link.redeem(sb, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz");
  assert.equal(cancelled.ok, false);
  assert.equal(calls.length, 3);
});
