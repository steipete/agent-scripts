#!/usr/bin/env node
// Regression anchors for map.ts: runs the mapper over fixtures/ and diffs the dense output
// against fixtures/expected/. Dependency-free; each fixture dir holds ONE file so output
// order never depends on readdir order.
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const skillDir = dirname(fileURLToPath(import.meta.url));
const mapTs = join(skillDir, 'map.ts');
const fixtures = join(skillDir, 'fixtures');
const workDir = mkdtempSync(join(tmpdir(), 'project-structure-selftest-'));

const CHECKS = [
  ['ts-dense', ['--include', 'ts']],
  ['swift-dense', ['--include', 'swift']],
  ['swift-members', ['--include', 'swift', '--members']],
  ['swift-public', ['--include', 'swift', '--public-only']],
  // Single file via nested include: skeleton blocks follow walk order, which is
  // filesystem-dependent across multiple files.
  ['swift-skeleton', ['--include', 'swift/visibility', '--mode', 'skeleton']],
].filter(([name]) => !process.argv.includes('--swift-only') || name.startsWith('swift-'));

let failed = 0;
for (const [name, flags] of CHECKS) {
  const outFile = join(workDir, `${name}.txt`);
  // Forward execArgv so a tsx loader (`node --import tsx selftest.mjs`, the documented
  // pre-23.6 fallback) reaches the child that parses map.ts.
  execFileSync(process.execPath, [...process.execArgv, mapTs, fixtures, ...flags, '--out', outFile], { stdio: ['ignore', 'ignore', 'inherit'] });
  const actual = readFileSync(outFile, 'utf8');
  const expected = readFileSync(join(fixtures, 'expected', `${name}.txt`), 'utf8');
  if (actual !== expected) {
    failed++;
    console.error(`FAIL ${name}`);
    const a = actual.split('\n');
    const e = expected.split('\n');
    for (let i = 0; i < Math.max(a.length, e.length); i++) {
      if (a[i] !== e[i]) {
        console.error(`  line ${i + 1}:`);
        console.error(`    expected: ${e[i] ?? '<missing>'}`);
        console.error(`    actual:   ${a[i] ?? '<missing>'}`);
      }
    }
  }
}
const hostileDir = join(workDir, 'hostile');
mkdirSync(hostileDir);
writeFileSync(join(hostileDir, 'Hostile.swift'), `${'  @.'.repeat(40)}\n@MainActor public func kept() {}\n`);
const hostileOut = join(workDir, 'hostile.txt');
try {
  execFileSync(process.execPath, [...process.execArgv, mapTs, hostileDir, '--out', hostileOut], {
    stdio: ['ignore', 'ignore', 'inherit'], timeout: 10000,
  });
  if (!readFileSync(hostileOut, 'utf8').includes('kept')) throw new Error('missing attributed function');
} catch (error) {
  failed++;
  console.error(`FAIL hostile Swift input: ${error.message}`);
}
rmSync(workDir, { recursive: true, force: true });

if (failed > 0) {
  console.error(`selftest FAILED (${failed}/${CHECKS.length + 1} checks)`);
  process.exit(1);
}
console.log(`selftest OK (${CHECKS.length + 1} checks)`);
