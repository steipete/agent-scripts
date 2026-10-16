import assert from "node:assert/strict";
import test from "node:test";
import { decodeHtmlEntities } from "./html-entities.js";

test("an out-of-range numeric entity stays in the caption", () => {
  assert.equal(decodeHtmlEntities("hello &#9999999; world &#39;"), "hello &#9999999; world '");
  assert.equal(decodeHtmlEntities("&#x110000;"), "&#x110000;");
  assert.equal(decodeHtmlEntities("&#38;"), "&");
});

test("valid and double-encoded caption entities still decode", () => {
  assert.equal(decodeHtmlEntities("&amp;#39; &#x1f980; &lt;text&gt;"), "' 🦀 <text>");
  assert.equal(decodeHtmlEntities("&#9999999999999999999999999999999;"), "&#9999999999999999999999999999999;");
  assert.equal(decodeHtmlEntities(""), "");
});
