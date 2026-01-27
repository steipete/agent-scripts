# Agent Scripts

This folder collects the Sweetistics guardrail helpers so they are easy to reuse in other repos or share during onboarding. Everything here is copied verbatim from `/Users/steipete/Projects/sweetistics` on 2025-11-08 unless otherwise noted.

Additional skills (copied 2025-12-31) are from @Dimillian’s public `Dimillian/Skills` repository:

- `skills/swift-concurrency-expert`
- `skills/swiftui-liquid-glass`
- `skills/swiftui-performance-audit`
- `skills/swiftui-view-refactor`

## Syncing With Other Repos

- Treat this repo as the canonical mirror for the shared guardrail helpers. Whenever you edit `scripts/committer` or `scripts/docs-list.ts` in any repo, copy the change here and then back out to every other repo that carries the same helpers so they stay byte-identical.
- When someone says “sync agent scripts,” pull the latest changes here, ensure downstream repos have the pointer-style `AGENTS.MD`, copy any helper updates into place, and reconcile differences before moving on.
- Keep every file dependency-free and portable: the scripts must run in isolation across repos. Do not add `tsconfig` path aliases, shared source folders, or any other Sweetistics-specific imports—inline tiny helpers or duplicate the minimum code needed so the mirror stays self-contained.

## Pointer-Style AGENTS

- Shared guardrail text now lives only inside this repo: `AGENTS.MD` (shared rules + tool list).
- Every consuming repo’s `AGENTS.MD` is reduced to the pointer line `READ ~/Developer/jacobjnilsson/agent-scripts/AGENTS.MD BEFORE ANYTHING (skip if missing).` Place repo-specific rules **after** that line if they’re truly needed.
- Do **not** copy the `[shared]` or `<tools>` blocks into other repos anymore. Instead, keep this repo updated and have downstream workspaces re-read `AGENTS.MD` when starting work.
- When updating the shared instructions, edit `agent-scripts/AGENTS.MD`, mirror the change into `~/AGENTS.MD` (Codex global), and let downstream repos continue referencing the pointer.

## Committer Helper (`scripts/committer`)

- **What it is:** Bash helper that stages exactly the files you list, enforces non-empty commit messages, and creates the commit.

## Docs Lister (`scripts/docs-list.ts`)

- **What it is:** tsx script that walks `docs/`, enforces front-matter (`summary`, `read_when`), and prints the summaries surfaced by `pnpm run docs:list`. Other repos can wire the same command into their onboarding flow.
- **Binary build:** `bin/docs-list` is the compiled Bun CLI; regenerate it after editing `scripts/docs-list.ts` via `bun build scripts/docs-list.ts --compile --outfile bin/docs-list`.

## Browser Tools (`bin/browser-tools`)

- **What it is:** A standalone Chrome helper inspired by Mario Zechner’s [“What if you don’t need MCP?”](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/) article. It launches/inspects DevTools-enabled Chrome profiles, pastes prompts, captures screenshots, and kills stray helper processes without needing the full Oracle CLI.
- **Usage:** Prefer the compiled binary: `bin/browser-tools --help`. Common commands include `start --profile`, `nav <url>`, `eval '<js>'`, `screenshot`, `search --content "<query>"`, `content <url>`, `inspect`, and `kill --all --force`.
- **Rebuilding:** The binary is not tracked in git. Re-generate it with `bun build scripts/browser-tools.ts --compile --target bun --outfile bin/browser-tools` (requires Bun) and leave transient `node_modules`/`package.json` out of the repo.
- **Portability:** The tool has zero repo-specific imports. Copy the script or the binary into other automation projects as needed and keep this copy in sync with downstream forks. It detects Chrome sessions launched via `--remote-debugging-port` **and** `--remote-debugging-pipe`, so list/kill works for both styles.

## Sync Expectations

- This repository is the canonical mirror for the guardrail helpers used in mcporter and other Sweetistics projects. Whenever you edit `scripts/committer`, `scripts/docs-list.ts`, or related guardrail files in another repo, copy the changes back here immediately (and vice versa) so the code stays byte-identical.
- When someone asks to “sync agent scripts,” update this repo, compare it against the active project, and reconcile differences in both directions before continuing.

## Agent Instructions (pointer workflow)

- The only full copies of the guardrails are `agent-scripts/AGENTS.MD` and `~/AGENTS.MD`. Downstream repos should contain the pointer line plus any repo-local additions.
- During a sync sweep: pull latest `agent-scripts`, ensure each target repo’s `AGENTS.MD` contains the pointer line at the top, append any repo-local notes beneath it, and update the helper scripts as needed.
- If a repo needs custom instructions, clearly separate them from the pointer so future sweeps don’t overwrite local content.
- For submodules (Peekaboo/*), repeat the pointer check inside each subrepo, push those changes, then bump submodule SHAs in the parent repo.
- Skip experimental repos (e.g., `poltergeist-pitui`) unless explicitly requested.
