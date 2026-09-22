---
name: github-cache-hygiene
description: "GitHub quota/cache hygiene: Gitcrawl archives, Octopool-backed gh, freshness, limits."
---

# GitHub Cache Hygiene

Goal: discover in the local Gitcrawl archive first, then use the existing Octopool-backed `gh` shim for current GitHub metadata and authorized writes.

## Default Path

Start with local archive reads:

```bash
gitcrawl search prs "<terms>" -R owner/repo --state open --json number,title,url
```

```bash
gitcrawl threads owner/repo --numbers 123 --include-closed --json
```

`--include-closed` keeps closed or merged candidates in scope. Archive state can lag GitHub; it is not proof of current state.

Then use bare PATH `gh` when current metadata is needed. On Peter's machines it is expected to be the Octopool-backed shim, so supported JSON reads share the fleet cache without changing authentication or command routing:

```bash
gh search issues "<terms>" -R owner/repo --state open --json number,title,state,url,updatedAt,labels,author
gh search prs "<terms>" -R owner/repo --state open --json number,title,state,url,updatedAt,isDraft,author
gh issue list -R owner/repo --state open --author user --assignee user --label bug --json number,title,url
gh pr list -R owner/repo --state open --author user --label dependencies --json number,title,url
gh issue view 123 -R owner/repo --json number,title,state,body,labels,url
gh pr view 123 -R owner/repo --json number,title,state,url,headRefName,headRefOid
gh pr checks 123 -R owner/repo --json name,state,bucket,link
gh run list -R owner/repo --branch branch-name --json databaseId,workflowName,status,conclusion,url
gh pr diff 123 -R owner/repo --patch
```

Use exact refs and narrow fields. `--json` selects output, not a reader identity.
In Octopool 0.7.1, PR `mergeStateStatus` and issue `comments` select native gh
for the entire field bundle. PR comment/review/commit exports also retain native
handling. Request those fields when needed, but omit them from descriptive reads
that do not consume them. Never remove merge/review gates merely to raise cache
reuse, or split one decision into separately timed reads without preserving its
consistency contract.

Supported human output and recognized landing GraphQL projections can also relay.
Supported `gh api --paginate`/`--slurp` and `--hostname github.com` reads need not
bypass Octopool. Use the installed version's CLI contract and observed routing;
an absolute `gh` path alone does not establish that it is the native binary.

Avoid broad loops like one `gh issue view` per result when a single `gh search` or `gh issue list --json ...` can answer the first-pass question.

For CI, avoid tight `gh run list` / `gh run view` polling loops. After a push or workflow dispatch, identify one exact run, then use an exact-run watcher or poll that run at 30s, 60s, then 120s intervals.
Check the expected head SHA and run attempt. A broad or filtered list can lag even
on a fresh upstream acquisition; its newest row is not final CI evidence. Fetch logs once, only after failure or explicit request. Reuse prior output instead of re-reading completed runs.

## Freshness

Local answers are good for discovery, duplicate search, old thread review, author/label triage, and "is there likely already an issue/PR?" checks.

Use a live call when:

- writing, commenting, closing, merging, rerunning, or editing
- checking final current state before a maintainer action
- verifying CI status after a push
- the local result is missing or obviously stale
- the user asks for latest/live state

Hydrate exact PR details only when the local archive needs files, commits, checks, or run summaries for repeated review:

```bash
gitcrawl sync owner/repo --numbers 123 --with pr-details
```

This refresh spends GitHub API calls and updates Gitcrawl's archive, not Octopool's separate `gh` cache. Bare `gh` reads do not auto-hydrate the Gitcrawl archive.

`gitcrawl gh` is retired and exits `2` with a migration note. Replace those recipes with archive reads followed by bare `gh`; the note is not an authentication failure. Do not run `octopool login`, change tokens/auth/PATH/config, or bypass the existing shim to repair a retired command.

After a write, do one targeted fresh readback, not a broad rescan.
Use `OCTOPOOL_FRESH=1` or an explicit `Cache-Control: max-age=0` for relay reads.
Supported PR decision fields such as `state`, `headRefOid` and `statusCheckRollup`
automatically revalidate. Descriptive fields such as `title` can reuse cache.

`gh api --include` uses native gh and caller credentials. It changes identity,
quota and potentially visibility; it is not a freshness switch or a guaranteed
stale-list workaround. Keep caller-owned permission and merge decisions on their
required identity path. A fresh relay MISS with an old list does not by itself
prove expired cache reuse, and a HIT after revalidation does not prove zero
upstream requests.

## Octopool

Inspect cache behavior when rate limits are suspected:

```bash
octopool whoami
octopool health
octopool stats --since 1h
octopool stats --since 24h --json
```

Prioritize cached eligible responses divided by eligible requests. Retain the UTC
window, numerator, denominator, misses, bypasses and coalesced requests. Compare
route/client mix, explicit freshness and latency before attributing a change.
These are response-reuse metrics, not GitHub quota savings. Pool totals cover all
callers, while client tables cover the authenticated caller. Native GraphQL and
direct clients are outside relay metrics; absence from a bounded sample is not
proof of a broken installation.

Check the actual execution context. A host shim can work while a container uses
a separate native read-only wrapper. Preserve that wrapper's allowlist and
credential boundary; never mount host mutation credentials to gain cache coverage.

Use `OCTOPOOL_NO_FALLBACK=1` only for a bounded, known-supported relay read.
It blocks a relay-to-native handoff, but deliberately unsupported commands can
still delegate directly. Success alone is therefore not universal relay proof.
Pair it with a known supported command and observed route/cache evidence. A
separate native wrapper may ignore this variable entirely. Do not set it globally;
mutations and unsupported reads still need real `gh`.

For relay-only proof:

```bash
OCTOPOOL_NO_FALLBACK=1 gh api repos/owner/repo --jq .full_name
```

## Agent Etiquette

Batch questions by repo and state. Reuse data already printed in the session. Back off CI polling; inspect logs only once for a failed run. Use bare PATH `gh` for ordinary reads and authorized writes; let Octopool own fallback to the real CLI. Do not bypass the shim with an absolute real-`gh` path or a binary override to replace retired Gitcrawl recipes.
