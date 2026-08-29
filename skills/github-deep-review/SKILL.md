---
name: github-deep-review
description: "GitHub deep review: bugs, PRs, best fix, stale-or-real, read code first."
---

# GitHub Deep Review

Review like Peter: high-confidence, evidence-first, code-aware, and willing to say "not proven" when the trail is weak. The goal is not a generic summary. The goal is to understand the bug class, find the real cause if possible, decide the best fix after reading enough code, and call out whether a larger refactor would improve the design.

## Start

Use `gh`, not web browsing, for GitHub refs:

```bash
gh issue view <n> --json number,title,state,author,body,comments,labels,updatedAt,url
gh pr view <n> --json number,title,state,author,body,comments,reviews,files,commits,statusCheckRollup,mergeStateStatus,headRefName,headRepositoryOwner,url
gh pr diff <n> --patch
```

For PRs, collect author context by default unless the author is Peter (`steipete` or an obvious Peter-owned account). Use the local workflow in `~/Projects/agent-scripts/skills/github-author-context/SKILL.md` and include a short `Author context:` block near the top of the review when the author is not Peter.
After merge/rejection/close/review, use that same author-context workflow to append a contributor note only when the interaction creates durable future-review signal.

For repo-local review, also inspect:

```bash
git status --short --branch
git fetch origin
git log --oneline --decorate -20
rg "<key symbol/error/config/endpoint>"
```

If the repo has local instructions, issue/PR skills, docs lists, test guidance, or maintainer runbooks, read those before deciding.

## Review Contract

Always answer these, explicitly:

- URL/ref: issue or PR number and affected surface.
- What is the bug or behavior being fixed?
- Can we identify the root cause? If yes, where in code and why. If no, what evidence is missing.
- For regressions, who/what introduced it and when? Include commit/PR provenance when traceable by bounded history; say unknown instead of guessing.
- Is the current/proposed fix the best possible fix after reading adjacent code?
- Would a bigger refactor improve correctness, clarity, or future maintainability?
- What proof exists: tests, live repro, CI checks, docs, dependency docs/source, shipped/current behavior.
- What remains risky or unverified.

## Code Reading Depth

Read past the first touched file. Follow the real call path:

- entrypoint -> validation/parsing -> routing/dispatch -> owner module -> shared helper -> persistence/network/runtime boundary
- config/schema/docs -> runtime usage -> doctor/migration/fix path
- provider/channel/plugin owner code -> generic core seam, only if multiple owners need it
- tests around the touched surface plus adjacent regression tests

When behavior depends on a dependency, read the upstream docs/source/types or current package contract before assuming.

Prefer current source and executable proof over issue comments. Treat stale comments, old CI, and old release behavior as hints until rechecked.

## Provenance

For bug/regression reviews, include a compact `Provenance:` answer when feasible:

- Use `git log -S/-G`, `git blame`, and linked PRs/issues to locate candidates, not prove introduction. Before saying `introduced by`, inspect raw parents with `git --no-replace-objects cat-file -p <sha>` and verify that `git --no-replace-objects diff --no-ext-diff --no-textconv <raw-parent> <sha> -- <path>` changed the implicated behavior, using tests/repro when feasible. A genuine root needs raw-header proof that it has no parents.
- Blame `^sha`, porcelain `boundary`, and shallow/grafted history alone are not introduction proof. `--root` can hide boundary markers; `git show` and `rev-list --parents` can disguise a shallow boundary as a root. An available raw parent permits explicit comparison even at a shallow boundary; missing parents or an unverifiable patch require `unknown` with the gap, not inference from a subject, date, or author.
- Separate code author, introducing PR author, merger, committer, automation trigger, and current PR author. Verify identities and triggers from explicit metadata/events; a role is not proof of causation, and an unverified identity stays unknown.
- Use `made visible by` only for a verified trigger and `carried forward by` only for verified preexisting behavior. Apply the same evidence bar to summaries and owner hints, not just a `Provenance:` field. Include confidence: `clear`, `likely`, or `unknown`.
- For features, docs, and refactors, write `N/A`; for untraceable bugs, report `unknown` with the missing evidence. Missing provenance does not invalidate an independently proven bug.

## Fix Quality Bar

Good fixes usually:

- live at the ownership boundary where the bug belongs
- preserve public/backward-compatible behavior unless the issue is about retiring it
- add a regression test at the smallest meaningful seam
- avoid broad special cases, hidden migrations, semantic sentinels, and provider/channel IDs in generic core
- update docs/changelog when user-visible behavior changes
- fail clearly in runtime paths and repair through doctor/migration paths when that is the established contract

Call out when a fix is only symptom-level. If a slightly larger refactor makes the invariant obvious and reduces future bugs, recommend it. If the refactor widens risk without improving the bug class, say so.

## PR Review Shape

Lead with findings when reviewing a PR. Findings need file/line/symbol references and a concrete failure mode. Avoid vague "consider" comments.

If no blocking issues:

- say no blocking correctness issues found
- list the strongest proof checked
- name residual risk/test gaps
- answer whether the design is the best available shape

Do not approve, comment, close, merge, push, or land unless the user asked for that action.

## Issue Review Shape

For bugs/issues:

1. Reconstruct the reporter's scenario and affected version/surface.
2. Check whether current `main` already fixes it.
3. Reproduce or create a minimal local/live proof when feasible.
4. If clear, identify root cause and proposed fix.
5. If solved on `main`, only comment/close when the user asks; include proof and the canonical commit/PR if known.

If reproduction is not feasible, say exactly what blocks it and what evidence would make the decision reliable.

## Output Template

Use this shape when the user asks "what is this about", "is this the best fix", or "what did we fix":

```text
Ref: #123 / PR #456
Surface: <runtime/CLI/provider/channel/docs>

Bug: <one or two sentences>
Cause: <code path + confidence>
Provenance: <introduced/made visible/carried forward by commit/PR/date, or N/A/unknown>
Best fix: <what should change and why>
Refactor: <yes/no, specific shape>
Proof: <tests/live/CI/source/dependency docs>
Risk: <remaining uncertainty>
```

Keep it concise, but do not skip the cause/fix/refactor/proof decision.
