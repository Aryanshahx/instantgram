import test from "node:test";
import assert from "node:assert/strict";
import { WordFilter, filterFor, normalizeToken, DEFAULT_WORDS } from "../lib/moderation.js";

const f = filterFor({});

test("tricks are seen through", () => {
  assert.equal(normalizeToken("5H1T"), "shit");
  for (const t of ["fuck", "FUCK", "fuuuuck", "f*ck", "fu*k", "f u c k", "f.u.c.k", "fucking", "motherfucker", "#fuck", "sh!t", "$hit"]) {
    assert.equal(f.scan(t).clean, false, t);
  }
  for (const t of ["as", "pass", "class", "assess", "grape", "cocktail", "Gandhi", "hello world", "f***", "s***", "a b c", "scunthorpe"]) {
    assert.equal(f.scan(t).clean, true, t);
  }
});

test("blocked vs mild", () => {
  assert.equal(f.scan("you are a bitch").blocked, false);
  assert.equal(f.scan("madarchod").blocked, true);
  assert.equal(f.scan("just kill yourself now").blocked, true);
  assert.equal(f.scan("मादरचोद").blocked, true);
  assert.equal(f.scan("chutiya hai").blocked, false);
});

test("the panel can add, and allow words", () => {
  const g = filterFor({ blocked: ["scamlink"], mild: ["meanie"], allow: ["ass"] });
  assert.equal(g.scan("visit scamlink").blocked, true);
  assert.equal(g.scan("meanie").clean, false);
  assert.equal(g.scan("ass").clean, true);
  assert.ok(new WordFilter({ blocked: ["x y"] }).scan("a x y b").blocked);
});

test("default lists exist", () => {
  assert.ok(DEFAULT_WORDS.blocked.length > 20 && DEFAULT_WORDS.mild.length > 40);
});
