# Agent Scripts

Shared agent instructions, skills, and small portable helpers for Peter's local workspaces.

This repo is the canonical place for:
- `AGENTS.MD`: shared hard rules for Codex/Claude-style agents
- `skills/`: reusable workflow skills, including repo-owned skills exposed by symlink
- `scripts/`: dependency-light helpers used across projects
- `hooks/`: local guardrails such as skill validation

## Skills

Skills are the main routing layer. Each `skills/<name>/SKILL.md` has YAML front matter:

```yaml
---
name: skill-name
description: "Short generic trigger phrase."
---
```

Rules:
- Keep descriptions short and generic; optimize for routing, not documentation.
- Keep skill bodies terse and operational.
- Prefer helper scripts under `skills/<name>/scripts/` when a workflow has repeatable commands.
- Validate after edits: `scripts/validate-skills`.
- Quote `description` in front matter.

Global discovery is built by `scripts/sync-skills` (idempotent; run on every Mac after cloning or adding skills):
- Codex scans nested dirs, so it gets whole-root links: `~/.codex/skills/agent-scripts -> ~/Projects/agent-scripts/skills`, `~/.codex/skills/manager -> ~/Projects/manager/skills`.
- Claude Code loads only `~/.claude/skills/<name>/SKILL.md` (exactly one level deep; per-entry symlinks are followed, category subfolders are not scanned — verified on 2.1.197). It gets a flat per-skill link mirror covering both repos plus machine-local `~/.codex/skills/<name>` extras.
- Name collisions resolve agent-scripts > manager > codex-local; the script prints skipped duplicates and prunes broken/stale managed links.
- Real destination files and directories are preserved. A real Claude skill directory with a Codex backlink to that same directory satisfies local ownership; other real destination conflicts are reported and make sync fail.

For the specific legacy topology `~/.claude/skills/NAME/NAME -> ~/.codex/skills/NAME -> ~/.claude/skills/NAME`, invoke the sync owner directly with an explicit allowlist:

```bash
/absolute/path/to/agent-scripts/scripts/sync-skills --repair-nested-self-links --dry-run -- boxd-cli boxd-setup-deploy
```

```bash
/absolute/path/to/agent-scripts/scripts/sync-skills --repair-nested-self-links -- boxd-cli boxd-setup-deploy
```

This mode validates every candidate before unlinking only the extra nested leaves. It preserves the real skill directories, assets, and valid Codex backlinks, and exits before creating roots, building mirrors, pruning, or touching instruction pointers. Names must start with an ASCII letter or digit and contain only letters, digits, `.`, `_`, or `-`; duplicates, missing names, and unknown arguments are rejected. A missing nested leaf is a no-op only with the expected surrounding topology. Redirected/inaccessible roots, unexpected objects or literal targets, and changed directory/link identities cause refusal. Rechecks before each unlink are not atomic concurrency protection; a later error stops the batch and reports removals already completed, without rollback.

The read-only `skills/fleet-maintenance/scripts/agent-skill-links-audit.sh` reports same-name nested ancestor loops as `reason=nested-self-link`. This is narrow detection, not an exhaustive graph validator. Its `--repair` remains a broad sync through `~/Projects/agent-scripts/scripts/sync-skills`; it is not the scoped repair above. Run `scripts/test-sync-skills` for isolated fixture coverage; `scripts/test-sync-skills --recurrence-only /absolute/path/to/old-sync-skills` runs the unchanged recurrence assertion against an original helper.

Shared personal skills live as real folders in `skills/`. Public OpenClaw shared skills live in `../agent-skills` and are exposed here with tracked relative symlinks. Repo-owned skills stay canonical in their repo and are exposed here the same way, for example:

```text
skills/autoreview -> ../../agent-skills/skills/autoreview
skills/discrawl -> ../../discrawl/.agents/skills/discrawl
```

Current symlinked repo-owned skills include `birdclaw`, `discrawl`, `gog`, `imsg`, `slacrawl`, `wacli`, and `wacrawl`.

## Agent Instructions

Shared hard rules live in `AGENTS.MD`.

Global setup (also maintained by `scripts/sync-skills`; Claude Code reads `CLAUDE.md` only, so it links to the shared `AGENTS.MD`):
- `~/.codex/AGENTS.md -> ~/Projects/agent-scripts/AGENTS.MD`
- `~/.claude/CLAUDE.md -> ~/Projects/agent-scripts/AGENTS.MD`
- `~/.claude/AGENTS.md -> ~/Projects/agent-scripts/AGENTS.MD`

Downstream repos should use a pointer-style `AGENTS.MD`:

```text
READ ~/Projects/agent-scripts/AGENTS.MD BEFORE ANYTHING (skip if missing).
```

Repo-specific rules go below that pointer. Do not copy the shared blocks into downstream repos.

## Helpers

`scripts/sync-skills`
- Builds the per-machine skill mirror: Codex whole-root links, Claude flat per-skill links, shared `AGENTS.MD` pointers.
- Idempotent; prints changes only, prunes broken/stale managed links, never clobbers real files.
- No arguments runs ordinary sync; `--help` prints usage. Only the scoped `--repair-nested-self-links` mode accepts `--dry-run`.

`scripts/validate-skills`
- Checks every `skills/*/SKILL.md`.
- Verifies YAML front matter plus required `name` and `description`.
- Enable as a local hook with `git config core.hooksPath hooks`.

`scripts/docs-list.ts`
- Walks `docs/`.
- Enforces `summary` and `read_when` front matter.
- Prints onboarding summaries for repos that wire it in.

`scripts/browser-tools.ts`
- Standalone Chrome DevTools helper.
- Common commands: `start --profile`, `nav <url>`, `eval '<js>'`, `screenshot`, `console`, `network`, `search --content "<query>"`, `content <url>`, `inspect`, `kill --all --force`.
- Build optional binary with `bun build scripts/browser-tools.ts --compile --target bun --outfile bin/browser-tools`.

## Syncing

Treat this repo as canonical for shared agent rules and portable helper scripts.

When syncing downstream repos:
- Pull latest here first.
- Ensure each target repo starts with the pointer-style `AGENTS.MD`.
- Preserve repo-local rules below the pointer.
- Copy helper changes both directions only when the helper is meant to stay byte-identical.
- Keep scripts dependency-free and portable; no repo-specific imports or path aliases.

For submodules, repeat the pointer check inside each subrepo, push those changes, then bump submodule SHAs in the parent repo.
