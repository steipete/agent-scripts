import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { decodeHtmlEntities } from "./html-entities.js";

const vtdPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "vtd.js");
const EMPTY_VTT = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n[Music]\n";
const NONEMPTY_VTT = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello from captions\n";

function writeFakeYtDlp(binDir) {
  fs.mkdirSync(binDir, { recursive: true });
  const bin = path.join(binDir, "yt-dlp");
  fs.writeFileSync(
    bin,
    `#!/bin/sh
set -eu
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out=$arg
  fi
  prev=$arg
done
if [ -z "$out" ]; then
  echo "fake yt-dlp missing -o" >&2
  exit 2
fi
cp "$VTD_FIXTURE_VTT" "$(dirname "$out")/fixture.vtt"
`,
  );
  fs.chmodSync(bin, 0o755);
}

function runTranscript({ vtt, timestamps }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "vtd-test-"));
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "vtd-subs-"));
  const binDir = path.join(root, "bin");
  const fixture = path.join(root, "fixture.vtt");
  writeFakeYtDlp(binDir);
  fs.writeFileSync(fixture, vtt);
  const args = ["transcript", "--url", "https://example.com/video"];
  if (timestamps) args.push("--timestamps");

  return new Promise((resolve) => {
    const child = spawn(process.execPath, [vtdPath, ...args], {
      env: {
        ...process.env,
        PATH: `${binDir}${path.delimiter}${process.env.PATH ?? ""}`,
        VTD_FIXTURE_VTT: fixture,
        TMPDIR: root,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("close", (code) => {
      const outsideSurvived = fs.existsSync(outside);
      const ownedSubs = fs.readdirSync(root).filter((name) => name.startsWith("vtd-subs-"));
      fs.rmSync(root, { recursive: true, force: true });
      fs.rmSync(outside, { recursive: true, force: true });
      resolve({ code, stdout, stderr, outsideSurvived, ownedSubs });
    });
  });
}

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

test("timestamped empty subtitles fail the same way as an empty paragraph", async () => {
  const plain = await runTranscript({ vtt: EMPTY_VTT, timestamps: false });
  const stamped = await runTranscript({ vtt: EMPTY_VTT, timestamps: true });
  assert.notEqual(plain.code, 0);
  assert.match(plain.stderr, /empty transcript from subtitles/);
  assert.equal(stamped.code, plain.code);
  assert.equal(stamped.stderr, plain.stderr);
  assert.equal(stamped.stdout, plain.stdout);
  assert.equal(plain.outsideSurvived, true);
  assert.equal(stamped.outsideSurvived, true);
  assert.equal(plain.ownedSubs.length, 0);
  assert.equal(stamped.ownedSubs.length, 0);
});

test("timestamped non-empty subtitles still print the cleaned paragraph", async () => {
  const plain = await runTranscript({ vtt: NONEMPTY_VTT, timestamps: false });
  const stamped = await runTranscript({ vtt: NONEMPTY_VTT, timestamps: true });
  assert.equal(plain.code, 0);
  assert.equal(stamped.code, 0);
  assert.equal(stamped.stdout, "Hello from captions\n");
  assert.equal(stamped.stdout, plain.stdout);
  assert.equal(stamped.stderr, "");
  assert.equal(plain.outsideSurvived, true);
  assert.equal(stamped.outsideSurvived, true);
  assert.equal(plain.ownedSubs.length, 0);
  assert.equal(stamped.ownedSubs.length, 0);
});
