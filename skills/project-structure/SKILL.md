---
name: project-structure
description: "Generate a single-file compressed symbol map of a TypeScript or Swift repository — files, exported symbols, typed signatures, plugin boundaries — sized to fit an LLM context window. Use for whole-project reasoning: duplication hunting, refactor planning, architecture recon, or feeding another agent a full-project map."
---

# Project Structure

Compress a TS or Swift repo into one map file an agent can load whole. Backed by `map.ts` next to this file. TS: parse-only TS compiler, no type-check; ~8k files in ~5s; resolves the `typescript` package from the target repo, falling back to this skill dir. Swift: zero-dependency regex/brace-depth scanner built into `map.ts` (no `typescript` needed for pure-Swift repos). Requires Node >= 23.6 (native type stripping) or `npx tsx`. `.ts`/`.tsx` and `.swift` files are detected by extension; a repo may mix both.

## Run

```bash
node <this-skill-dir>/map.ts <repoRoot> [flags]
```

`<this-skill-dir>` is the base directory of this skill as announced when the skill loads (canonical: `~/Projects/agent-scripts/skills/project-structure`).

Output: one map file (default `project-structure-map.txt` in cwd) plus a JSON stats line (files, symbols, bytes, approxTokens) on stdout.

## Flags

- `--out <file>` — output path.
- `--mode dense|skeleton|exports|sigs|full` — default `dense`.
  - `dense`: dir-grouped, one line per file: `file fn:a,b ty:T cl:C c:x re:./y`. Recon tier. File extensions are stripped for compactness, so a same-basename TS and Swift file in one dir share a line prefix (theoretical in practice; grep the repo to disambiguate).
  - `skeleton`: one symbol per line, names only.
  - `exports`: exported symbols with full typed signatures, type bodies, first doc-comment line. Refactor-decision tier. **TS-only** — Swift files fall back to their dense-style line (no fabricated signatures).
  - `sigs`: exports but type/interface bodies collapsed to member names (only ~10% smaller than exports; rarely worth it). TS-only, same Swift fallback.
  - `full`: exports + non-exported top-level symbols (marked `internal`; internal consts appear only when function-valued or explicitly typed — untyped internal consts are filtered as noise). TS-only, same Swift fallback.
- `--include a,b,c` — paths to map, relative to repoRoot (default: all top-level dirs, minus skips/boundaries). Accepts nested paths, not just top-level dirs: `--include src/channels/turn` maps exactly that subtree. Headers stay repoRoot-relative, so running from repo root with `--include <subsystem>` is the recommended way to map a subsection.
- `--boundary x,y` — dirs listed as boundary index only: child module names + one-line `package.json` descriptions, no symbol content. Use for plugin/extension trees.
- `--include-tests` — keep test files and test-support infra (default: both excluded; Swift test detection is path-based: `Tests?/` dirs and `*Tests.swift`).
- `--no-docs` — strip doc comments (saves ~13% on typed modes).
- `--fn-consts-only` — drop non-function const exports (on Swift files: drops every let/var symbol — closure-valued consts are indistinguishable without type info). Caution: silently drops files whose only exports are consts (plugin definition objects, schemas, registries). Prefer keeping consts in `dense` (names are cheap).
- `--re-counts` — collapse re-export path lists to a count (dense; saves ~10%).
- `--max-per-kind N` — cap each symbol-kind list per file with `+n` overflow marker (dense; 10–12 is safe).
- `--members` — Swift only (ignored for TS files): additionally emit one-level-deep methods/properties as `Type.member`; extension members appear under their target type.
- `--public-only` — Swift only (ignored for TS files): keep only symbols whose written access is `open`/`public`.

When `--include` is absent, source files sitting directly in repoRoot are scanned too (so pointing repoRoot at a leaf source dir works); with `--include`, only the listed paths are walked.

## Swift specifics

Zero-dependency line scanner (lexical masking of comments/strings + brace-depth tracking), validated 1:1 against SourceKitten on 1,850 files across two real repos (100% top-level symbol agreement) at ~100× SourceKitten's speed. Known limitations (accepted tradeoffs of the parserless design): one declaration per line is assumed — a member on the same line as its type (`struct Box { var v = 1 }`) or a second semicolon-separated declaration is not emitted; bare `/…/` regex literals are not masked (lexically ambiguous with division), so a brace inside one can desync depth for the rest of that file — extended `#/…/#` literals are masked correctly; comments or raw/multiline literals nested *inside* string interpolations, emoji identifiers, and `#if` branches whose alternative headers declare *differently named* containers are best-effort (same-name platform-split containers work). Kinds: `fn` = func (incl. operator funcs); `cl` = class, actor; `ty` = struct, enum, protocol, typealias, macro, and extensions as `extension:TargetType`; `c` = let/var. Visibility is appended per symbol as `[open]`/`[public]`/`[package]`/`[private]`/`[fileprivate]`; `internal` (Swift's default) is deliberately untagged to save map bytes. Tags reflect *written* access; members of protocols/extensions without a written modifier inherit the container's access. Swift puts most code inside types, so the default top-level map is thin (median ~2 symbols/file) — reach for `--members` when method-level recon matters.

## Sizing

TS (reference: openclaw, ~7M LOC, ~14k source files; o200k tokens; byte/4 estimate runs ~5–15% high — verify with a real tokenizer when near a budget):

- exports, whole repo: ~2.5M tokens — never fits; scope typed maps to one subsystem.
- exports, one subsystem (e.g. src/channels, 257 files): ~79k.
- skeleton, whole repo: ~717k (fits 1M-class windows).
- dense, whole repo: ~430k real.
- dense, `src`+`packages` + extensions boundary, `--re-counts --max-per-kind 12`: ~218k real.
- dense, `src` only + boundaries, `--re-counts --max-per-kind 10`: ~197k real (fits a 200k window).

Swift (reference: Peekaboo, 1,122 source files after test exclusion; byte/4 estimates):

- dense top-level: ~34k tokens (3,962 symbols).
- dense `--members`: ~197k (20,909 symbols) — ~6× top-level.
- dense `--public-only`: ~12k (1,285 symbols).
- dense `--members --public-only`: ~74k — the API-surface tier for big Swift repos.

## Workflow guidance

- Two-tier: dense whole-repo map for reconnaissance and candidate enumeration; then `--mode exports --include <subsystem>` (TS) or `--members --include <subsystem>` (Swift) for the actual refactor decision. Names alone cannot distinguish duplicates from overloads, facades, or `.runtime.ts` lazy seams — verify every dense-tier finding against typed signatures or source before acting.
- Feeding codex CLI: turn input hard-caps at 1,048,576 chars (~260k tokens); pipe the map via stdin. Bigger maps need a direct Responses API call ($codex-huge-context) or a model with a larger window.
- Do not bother with dictionary/abbreviation compression: measured on openclaw, total possible savings were 292 tokens (0.15%) — BPE already compresses repeated identifiers.
- Map findings are leads, not verdicts: spot-verify file paths and claims with grep before acting on any model analysis of a map.
- `node selftest.mjs` (or `node selftest.mjs --swift-only` without TypeScript installed, in this skill dir) diffs the mapper against checked-in fixtures for both languages — run it after editing `map.ts`.
