---
name: clawsweeper-status
description: "ClawSweeper status: URLs, workflow health, active workers, ops snapshot."
---

# ClawSweeper Status

## Quick Start

Run the bundled status script first:

```bash
/Users/steipete/Projects/agent-scripts/skills/clawsweeper-status/scripts/clawsweeper-status.sh
```

Useful options:

```bash
# Last 10 hours for the default target repo, openclaw/openclaw
/Users/steipete/Projects/agent-scripts/skills/clawsweeper-status/scripts/clawsweeper-status.sh --hours 10

# A different target repo
/Users/steipete/Projects/agent-scripts/skills/clawsweeper-status/scripts/clawsweeper-status.sh --repo openclaw/clawhub

# More rows per activity section
/Users/steipete/Projects/agent-scripts/skills/clawsweeper-status/scripts/clawsweeper-status.sh --limit 15
```

## Output Contract

Report these sections concisely:

- `Workers`: workflow state, Codex jobs against configured capacity, exact-review queue and target occupancy when available, and active workflow groups. Public queue aggregates remain usable without private target occupancy; `occupancy unavailable` does not mean zero.
- `Queue health`: lead with this whenever it is not `healthy`. Pending depth on its own is not a verdict — read the split the script prints underneath it:
  - `ready`/`admissible` near zero while pending is deep means the lane is deliberately holding items back, not stalled.
  - `Queue backoff: throttle_retry N` means GitHub is rate-limiting; the lane recovers on its own once quota returns.
  - `Queue parked (needs operator): review_retry_exhausted N` does **not** self-heal. Parked items retry at 5/10/20 minutes and then wait for a human. Always call these out explicitly.
  - `Shed since reset` climbing into the thousands means sustained overload, not a blip.
- `Publication tail`: aggregate pending/ready/backoff/parked/active counts and capacity when available, plus retry and parked reasons. This is separate from the review backlog, not per-target activity; legacy responses without this lane report `unavailable`.
- `Recently merged`: merged PR URLs plus one-line titles.
- `Recently reviewed`: ClawSweeper/Codex review comment URLs plus one-line comment summary.
- `Recently commented`: other recent ClawSweeper comment URLs plus one-line comment summary.
- `Recently closed`: closed issue/PR URLs plus one-line titles.

If the script returns no rows for a section, say `none found in window`.

## Efficient Data Sources

Prefer the script because it uses bounded API calls:

- field-bounded Actions run queries and bounded active-job probes from `openclaw/clawsweeper`;
- the small automation-limits config and exact-review queue status endpoint for capacity context;
- recent issue comments for review/comment URLs;
- a field-bounded closed-item search for close URLs and actors;
- field-bounded recent merged PRs.

Do not browse the web for these checks. Use `gh` directly.

## Interpretation

- Cancelled repository-dispatch review runs are usually expected supersession when a newer event for the same item arrives.
- Count Codex usage from actual in-progress/queued jobs; use setup-action steps plus known lane names to identify Codex work.
- Treat `pending` workflow runs as concurrency waiters, not queued Codex jobs.
- Treat stale worker counts cautiously; compare the status-filtered `gh run list` results with the default recent-run list when numbers disagree.
- Queue reads stay unauthenticated. Public oldest-pending age is useful without a private item key; missing health counts remain `unknown`, not zero.
- Use full GitHub URLs in the final answer.
