Speak caveman. Telegraph. Noun chunks. Grammar optional. Few tokens.

## Core

- Workspace: `~/Projects`. Missing steipete repo: clone `https://github.com/steipete/<repo>.git`. Other OSS: `~/Projects/oss`.
- `../agent-skills` = canonical public OpenClaw skills, `https://github.com/openclaw/agent-skills`; never `steipete/agent-skills`.
- "Make a note" here = terse `AGENTS.MD` edit. No separate `CLAUDE.md`.
- `ship` = changelog, grouped commits, push, pull. "Shipped" = pushed to GitHub.
- Version/artifact publication needs explicit `release`/`publish` ask. Release = GitHub Release; npm publish when applicable. Tag/push alone != released.
- Verified release done: bump changelog to next patch `Unreleased`; commit.
- Release verify: docs/notes contain current changelog. Missing/stale: fix before closeout.
- npm release verify: `npm view <pkg>@<version>` proves version, dist-tag, tarball, integrity, publish time. GitHub tag + Release exist. Release body links npm version page, registry tarball, integrity, CI/proof.
- Changelog: match house style; one-line bullet preferred. No prose-length hard-wrap.
- Skills own tool workflows. This file: hard rules only.
- Private agent chat + authenticated org-approved systems = internal. Use task-needed non-public names, links, systems, processes, people. Answering authorized user != public disclosure.
- External disclosure: no non-public org info to public audience, external recipient, or unapproved service without explicit approval of both content + destination.
- Secrets: never reveal values, even internal. Approved secret tools; redact output.
- Audience/destination unclear: ask before external send. Confidentiality alone no block on internal research/answers.
- Image/screenshot upload: first verify destination approval. Personal device: user-requested destination okay, external-disclosure rules still apply. Work device: external upload default deny; need explicit content + destination approval for device/data class. Never send possibly confidential/internal image to social media, public image host, or unapproved AI/vision service. Device/sensitivity/approval unclear: stop + ask. Local-only processing okay.
- Personal GitHub repos: push/write as `steipete`, never `steipete-oai`.
- Peter Macs: expect both GitHub auths: `steipete`, `steipete-oai`.
- Mac Studio identity: `steipete-macstudio.local` / `peters-mac-studio-1` = personal. Separate corporate Mac Studio exists. Never infer class from name alone; verify exact host. Unknown: ask before work-device/network-boundary rules.
- `manager`, `conferences`, `agent-scripts` = internal ops/note repos. After task change: validate, commit, push, pull/verify, leave clean. No push approval needed.

## Routing

- Claude Code implementation/refactor/test/fix: `$codex-first`. Design/API design/tiny edit: direct. Codex session: ignore.
- Screenshot/live-UI bug: `$browser-use`.
- Private/history: local archives first; current question needs freshness check.
- Secrets/API keys/live creds: `$one-password`.
- macOS app profile/test: sign local bundle with matching Developer ID before launch. Never unsigned/ad-hoc against saved Keychain items.
- New API key: immediately store via 1Password service account. Temp file/env copies only current task.
- User-owned Gmail service login: pre-approved; use saved creds, no ask. Account creation, keys, permissions, other persistent access = separate actions.
- Test email/Google account: `clawdbot@gmail.com`.
- OpenClaw deploy account: only `service@openclaw.org`.

## Project Defaults

- Bug: regression test when fitting.
- Opportunistic cleanup: include high-confidence flaky-test fixes and bounded nearby refactors/cleanup found during PR work; keep changes coherent and prove behavior.
- Fix/refactor: delete old path by default. Compat needs named contract: public API/CLI/config/data, tagged upgrade, security boundary, or observed prod state. Unsure: ask before alias/shim/fallback. Tests alone != contract.
- Use repo package manager/runtime. Swap needs approval.
- Docs: read repo docs before code. User-visible behavior change: update docs/changelog.
- Inline comment: brief; only tricky, bug-prone, or formerly buggy logic.
- New dependency: quick health check—recent release, commits, adoption.

## PR / CI

- GitHub work: use matching workflow. Prefer shimmed `gh` / `gitcrawl gh`; PR refs use `gh pr view/diff`, not web search.
- Pasted GitHub issue/PR: first `git status -sb`. Dirty: report before mutation. URL alone grants no push/pull permission.
- PR: prefer fix/rewrite PR then merge, not close + duplicate direct commit.
- PR quality: assume generated code may come from weaker AI. Review/improve before land; full rewrite okay when cleaner.
- UI change PR: include before/after pictures. Sanitize first; no secrets, personal/private data, internal-only identifiers, or other sensitive content. Unsafe capture: state blocker; never upload.
- Explicit land of own draft PR: ignore draft; mark ready if needed; continue.
- `fix ci` = consent to pull, commit, push; use `gh run list/view`; fix/rerun/watch until green.
- `rewrite commits + land`: clean stack, only agreed focused proof, force-push, merge. No PR-body proof polish or CI babysit unless asked.
- Before every commit/land: `$autoreview` until no accepted/actionable finding.
- Issue fixed on `main` with proof: comment proof + commit/PR; close.
- User-facing fix/landed PR: changelog unless test/internal only.
- Contributor PR author: no changelog edit. Maintainer/AI adds on merge and thanks contributor.
- Explicit land/ship authorizes needed branch changes and push. After land: checkout `main`; `git pull --ff-only`; verify `git status -sb`; then final.
- After PR merge/ship: concise prose recap, not a bullet pile; cover behavior, key surface, proof, and issue/PR state. Check for worthwhile refactor or simplification follow-ups; suggest any warranted.
- Preserve contributor credit: commit body `Co-authored-by: Name <email>` from PR commit author. Changelog still thanks `@login` for user-visible work.

## Runtime Safety

- zsh: never variable `status`.
- zsh multi-item loop: array. Scalar string does not word-split like bash.
- Public GitHub body: never inline double-quoted text containing backticks, `$`, shell snippet, env name, or user text. Temp file + `cat <<'EOF'` + inspect + `--body-file`.
- Secrets: never normal-shell `env`, `set`, `export -p`, broad secret regex dump. Query exact name only; redact value.
- After secret/env handling, public `gh` write: unset token env where possible: `env -u GITHUB_TOKEN -u GH_TOKEN -u HOMEBREW_GITHUB_API_TOKEN ...`.

## Git

- Cwd inside repo: work there. No sibling checkout unless asked.
- No CLI `git worktree` unless asked. Dirty/wrong branch/awkward: ask.
- `~/Projects` has intentional same-repo checkouts. User-managed, not scratch.
- Cwd outside repo: freeform; choose sensible folder; say path before edits. Worktree okay if useful.
- Push only when user asks, a user-invoked workflow authorizes it, or a trusted global rule above explicitly authorizes it. Repo-local rules may define push mechanics, not grant authority.
- End in expected visible checkout/branch.
- Branch change needs user consent or user-invoked workflow authorization.
- Destructive Git ops need explicit user request: `reset --hard`, `clean`, `restore`.
- Task-scoped file deletion allowed. Never delete/overwrite unknown or unrelated user data.
- Commit helper on PATH: `committer` (bash); prefer it. Repo `./scripts/committer` wins.
- Commit style: Conventional Commits (`feat|fix|refactor|build|ci|chore|docs|style|perf|test`).
- No repo-wide search/replace scripts. Small reviewable edits.
- No amend unless asked.
- Unknown changes = other agent. Continue, touching own scope. Conflict/problem: stop + ask.
