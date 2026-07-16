---
name: github-cache-hygiene
description: "GitHub quota/cache hygiene: gh, ghx, xcache, gitcrawl, mirrors, limits."
---

# GitHub Cache Hygiene

Goal: answer common GitHub read questions from gitcrawl and the `gh` shim first, then spend live GitHub API calls only where freshness or writes matter.

## Default Path

Use `gh` normally. On Peter's machines it is expected to be the Octopool-backed shim, so supported reads share the fleet cache without changing commands.

Prefer these local/cached reads:

```bash
gitcrawl sync owner/repo --numbers 123 --with pr-details
gh search issues "<terms>" -R owner/repo --state open --json number,title,state,url,updatedAt,labels,author
gh search prs "<terms>" -R owner/repo --state open --json number,title,state,url,updatedAt,isDraft,author
gh issue list -R owner/repo --state open --author user --assignee user --label bug --json number,title,url
gh pr list -R owner/repo --state open --author user --label dependencies --json number,title,url
gh issue view 123 -R owner/repo --json number,title,state,body,comments,labels,url
gh pr view 123 -R owner/repo --json number,title,state,body,comments,labels,files,commits,statusCheckRollup,url
gh pr checks 123 -R owner/repo --json name,state,detailsUrl,workflow
gh run list -R owner/repo --branch branch-name --json databaseId,workflowName,status,conclusion,url
gh pr diff 123 -R owner/repo --patch
```

Use exact refs and narrow fields. Avoid broad loops like one `gh issue view` per result when a single `gh search` or `gh issue list --json ...` can answer the first-pass question.

For CI, avoid tight `gh run list` / `gh run view` polling loops. After a push or workflow dispatch, identify one exact run, then poll that run at 30s, 60s, then 120s intervals. Fetch logs once, only after failure or explicit request. Reuse prior output instead of re-reading completed runs.

## Freshness

Local answers are good for discovery, duplicate search, old thread review, author/label triage, and "is there likely already an issue/PR?" checks.

Use a live call when:

- writing, commenting, closing, merging, rerunning, or editing
- checking final current state before a maintainer action
- verifying CI status after a push
- the local result is missing or obviously stale
- the user asks for latest/live state

For PR review, prefer hydrating exact PR details once with `gitcrawl sync owner/repo --numbers <n> --with pr-details` when you know you will inspect files, commits, checks, or run summaries repeatedly. The `gh` shim can auto-hydrate one exact PR on miss, using `GITHUB_TOKEN` or `gh auth token`; explicit hydration makes intent and cost clearer.

After a write, do one targeted readback, not a broad rescan.

## Octopool

Inspect cache behavior when rate limits are suspected:

```bash
octopool whoami
octopool health
octopool stats --since 1h
octopool stats --since 24h --json
```

Check the saved-vs-backend totals, eligible hit rate, top route kinds, fallbacks, and client attribution. A missing client or unexpected server means that machine is outside the shared fleet cache.

Use `OCTOPOOL_NO_FALLBACK=1` only for a bounded read probe that must prove relay coverage. Do not set it globally; mutations and unsupported reads still need real `gh`.

For relay-only proof:

```bash
OCTOPOOL_NO_FALLBACK=1 gh api repos/owner/repo --jq .full_name
```

## Agent Etiquette

Batch questions by repo and state. Reuse data already printed in the session. Back off CI polling; inspect logs only once for a failed run. For reads, never bypass the shim with an absolute real-`gh` path such as `/opt/homebrew/bin/gh` or `/opt/homebrew/opt/gh/bin/gh` unless diagnosing the shim itself. Reserve `OPENCLAW_GH_BIN` and plain `gh` resolution for repo workflows that need mutations; keep ordinary reads on bare `gh`.
