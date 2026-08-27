#!/usr/bin/env bash
set -euo pipefail

target_repo="openclaw/openclaw"
clawsweeper_repo="openclaw/clawsweeper"
hours="6"
limit="8"
run_limit="100"
bot_regex='(clawsweeper|openclaw-ci|github-actions)'

usage() {
  cat <<'USAGE'
Usage: clawsweeper-status.sh [--repo owner/name] [--hours N] [--limit N]

Shows recent ClawSweeper activity and worker health:
  - recently merged PRs
  - recently reviewed/commented items
  - recently closed items
  - active workflows and estimated active Codex jobs
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      target_repo="${2:?missing value for --repo}"
      shift 2
      ;;
    --clawsweeper-repo)
      clawsweeper_repo="${2:?missing value for --clawsweeper-repo}"
      shift 2
      ;;
    --hours)
      hours="${2:?missing value for --hours}"
      shift 2
      ;;
    --limit)
      limit="${2:?missing value for --limit}"
      shift 2
      ;;
    --run-limit)
      run_limit="${2:?missing value for --run-limit}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

since="$(date -u -v-"${hours}"H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ')"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

runs_json="$tmpdir/runs.json"
all_runs_jsonl="$tmpdir/all-runs.jsonl"
comments_json="$tmpdir/comments.json"
closed_items_json="$tmpdir/closed-items.json"
pulls_json="$tmpdir/pulls.json"
jobs_jsonl="$tmpdir/jobs.jsonl"
limits_json="$tmpdir/automation-limits.json"
exact_queue_json="$tmpdir/exact-review-queue.json"

activity_page_size=$((limit * 3))
if [ "$activity_page_size" -lt 10 ]; then
  activity_page_size=10
elif [ "$activity_page_size" -gt 20 ]; then
  activity_page_size=20
fi

closed_page_size=$((limit * 10))
if [ "$closed_page_size" -lt 50 ]; then
  closed_page_size=50
elif [ "$closed_page_size" -gt 100 ]; then
  closed_page_size=100
fi

normalize_runs='.[] | {
  id: .databaseId,
  name,
  event,
  status,
  conclusion,
  created_at: .createdAt,
  html_url: .url
}'

status_page_size="$run_limit"
if [ "$status_page_size" -gt 50 ]; then
  status_page_size=50
fi

fetch_runs_by_status() {
  local run_status="$1"
  local output="$2"

  gh api "repos/${clawsweeper_repo}/actions/runs?status=${run_status}&per_page=${status_page_size}" \
    --jq '.workflow_runs | map({
      databaseId: .id,
      name,
      event,
      status,
      conclusion,
      createdAt: .created_at,
      url: .html_url
    })' >"$output"
}

fetch_activity_page() {
  local endpoint_template="$1"
  local output="$2"
  local page_size="$activity_page_size"
  local error_file="$tmpdir/activity-error"

  while :; do
    if gh api "${endpoint_template/__PAGE__/$page_size}" >"$output" 2>"$error_file"; then
      return 0
    fi
    if [ "$page_size" -eq 1 ]; then
      cat "$error_file" >&2
      return 1
    fi
    page_size=$((page_size / 2))
    [ "$page_size" -lt 1 ] && page_size=1
  done
}

: >"$all_runs_jsonl"
gh run list --repo "$clawsweeper_repo" --limit "$run_limit" \
  --json databaseId,name,event,status,conclusion,createdAt,url \
  | jq -c "$normalize_runs" >>"$all_runs_jsonl"
run_query_failures=0
run_query_truncated=0
for status in in_progress queued waiting pending requested; do
  status_runs_json="$tmpdir/runs-${status}.json"
  if fetch_runs_by_status "$status" "$status_runs_json"; then
    jq -c "$normalize_runs" "$status_runs_json" >>"$all_runs_jsonl"
    status_run_count="$(jq 'length' "$status_runs_json")"
    if [ "$status_run_count" -ge "$status_page_size" ]; then
      run_query_truncated=$((run_query_truncated + 1))
    fi
  else
    run_query_failures=$((run_query_failures + 1))
  fi
done
bad_run_query_failures=0
bad_run_query_truncated=0
for conclusion_status in failure timed_out action_required; do
  conclusion_runs_json="$tmpdir/runs-${conclusion_status}.json"
  if fetch_runs_by_status "$conclusion_status" "$conclusion_runs_json"; then
    jq -c "$normalize_runs" "$conclusion_runs_json" >>"$all_runs_jsonl"
    conclusion_run_count="$(jq 'length' "$conclusion_runs_json")"
    if [ "$conclusion_run_count" -ge "$status_page_size" ]; then
      bad_run_query_truncated=$((bad_run_query_truncated + 1))
    fi
  else
    bad_run_query_failures=$((bad_run_query_failures + 1))
  fi
done
jq -s '
  {
    workflow_runs: (
      unique_by(.id)
      | sort_by(.created_at)
      | reverse
    )
  }
' "$all_runs_jsonl" >"$runs_json"
fetch_activity_page "repos/${target_repo}/issues/comments?sort=updated&direction=desc&per_page=__PAGE__&since=${since}" "$comments_json"
closed_pr_search="repo:${target_repo} is:pr is:closed is:unmerged closed:>=${since} sort:updated-desc"
closed_issue_search="repo:${target_repo} is:issue is:closed closed:>=${since} sort:updated-desc"
# GraphQL variable references must remain literal for gh to bind them.
# shellcheck disable=SC2016
closed_query='query($pullSearchQuery: String!, $issueSearchQuery: String!, $first: Int!) {
  pulls: search(type: ISSUE, query: $pullSearchQuery, first: $first) {
    nodes {
      ... on PullRequest {
        title url closedAt
        timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) {
          nodes { ... on ClosedEvent { createdAt actor { login } } }
        }
      }
    }
  }
  issues: search(type: ISSUE, query: $issueSearchQuery, first: $first) {
    nodes {
      ... on Issue {
        title url closedAt
        timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) {
          nodes { ... on ClosedEvent { createdAt actor { login } } }
        }
      }
    }
  }
}'
gh api graphql -f query="$closed_query" \
  -f pullSearchQuery="$closed_pr_search" \
  -f issueSearchQuery="$closed_issue_search" \
  -F first="$closed_page_size" >"$closed_items_json"
gh pr list --repo "$target_repo" --state merged \
  --search "merged:>=${since} sort:updated-desc" --limit "$activity_page_size" \
  --json title,url,mergedAt,mergedBy,labels >"$pulls_json"

if ! gh api "repos/${clawsweeper_repo}/contents/config/automation-limits.json" \
  -H "Accept: application/vnd.github.raw" \
  >"$limits_json" 2>/dev/null || ! jq -e 'type == "object"' "$limits_json" >/dev/null; then
  printf '{}\n' >"$limits_json"
fi

if command -v curl >/dev/null 2>&1 && \
  curl --fail --silent --show-error --connect-timeout 3 --max-time 8 \
    "${CLAWSWEEPER_EXACT_REVIEW_QUEUE_URL:-https://clawsweeper.openclaw.ai}/api/exact-review-queue" \
    >"$exact_queue_json" 2>/dev/null && \
  jq -e '
    type == "object" and
    (.pending | type == "number") and
    (.dispatching | type == "number") and
    (.leased | type == "number")
  ' "$exact_queue_json" >/dev/null; then
  exact_queue_available=true
else
  exact_queue_available=false
  printf '{}\n' >"$exact_queue_json"
fi

active_count="$(jq '[.workflow_runs[]
  | select(.status == "in_progress" or .status == "pending" or .status == "queued" or .status == "waiting" or .status == "requested")
] | length' "$runs_json")"
if [ "$exact_queue_available" = true ]; then
  exact_active_count="$(jq '(.dispatching // 0) + (.leased // 0)' "$exact_queue_json")"
  exact_running_count="$(jq '.leased // 0' "$exact_queue_json")"
else
  exact_active_count=0
  exact_running_count=0
fi
job_bearing_run_count="$(jq --argjson skip_exact "$exact_queue_available" '[.workflow_runs[]
  | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "requested")
  | select(($skip_exact | not) or (((.event == "repository_dispatch") and (.name | startswith("Review event item "))) | not))
] | length' "$runs_json")"
job_probe_limit="$run_limit"
active_ids="$(jq -r --argjson limit "$job_probe_limit" --argjson skip_exact "$exact_queue_available" '[.workflow_runs[]
  | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or .status == "requested")
  | select(($skip_exact | not) or (((.event == "repository_dispatch") and (.name | startswith("Review event item "))) | not))
] | sort_by(if .status == "in_progress" then 0 else 1 end)
  | .[0:$limit][]
  | .id' "$runs_json")"
probed_job_runs="$(printf '%s\n' "$active_ids" | awk 'NF { count += 1 } END { print count + 0 }')"
if [ "$job_bearing_run_count" -gt "$probed_job_runs" ]; then
  unprobed_job_runs=$((job_bearing_run_count - probed_job_runs))
else
  unprobed_job_runs=0
fi

: >"$jobs_jsonl"
job_batch_size=8
job_batch_count=0
while IFS= read -r run_id; do
  [ -n "$run_id" ] || continue
  (
    run_name="$(jq -r --argjson run_id "$run_id" '.workflow_runs[]
      | select(.id == $run_id)
      | .name' "$runs_json")"
    if jobs="$(gh run view "$run_id" --repo "$clawsweeper_repo" --json jobs \
      --jq '[.jobs[] | {name,status,conclusion,steps: [.steps[]?.name]}]' 2>/dev/null)"; then
      jq -cn --arg run_id "$run_id" --arg run_name "$run_name" --argjson jobs "$jobs" \
        '{run_id: $run_id, run_name: $run_name, jobs: $jobs, query_failed: false}'
    else
      jq -cn --arg run_id "$run_id" --arg run_name "$run_name" \
        '{run_id: $run_id, run_name: $run_name, jobs: [], query_failed: true}'
    fi
  ) >"$tmpdir/jobs-${run_id}.json" &
  job_batch_count=$((job_batch_count + 1))
  if [ "$job_batch_count" -ge "$job_batch_size" ]; then
    wait
    job_batch_count=0
  fi
done <<<"$active_ids"
wait
for job_file in "$tmpdir"/jobs-*.json; do
  [ -e "$job_file" ] || continue
  cat "$job_file" >>"$jobs_jsonl"
done

queued_count="$(jq '[.workflow_runs[] | select(.status == "queued" or .status == "waiting" or .status == "requested")] | length' "$runs_json")"
concurrency_waiters="$(jq '[.workflow_runs[] | select(.status == "pending")] | length' "$runs_json")"
bad_count="$(jq --arg since "$since" '[.workflow_runs[] | select(.created_at >= $since) | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required")] | length' "$runs_json")"

codex_job_regex='^Review shard|^Review, comment, and apply event item$|^Review commit|^Plan and review cluster$|^Run worker|^Execute credited fix|^Execute and apply cluster actions$|^assist$|^Generate and publish maintainer reports$'
codex_running="$(jq -s --arg regex "$codex_job_regex" '
def codex_job:
  (((.steps // []) | map(test("setup-codex"; "i")) | any) or
   ((.name // "") | test($regex; "i")) or
   (((.name // "") == "intake") and ((.run_name // "") | test("^repair commit finding intake$"; "i"))));
[.[] as $run
  | $run.jobs[]?
  | . + {run_name: $run.run_name}
  | select(.status == "in_progress")
  | select(codex_job)
] | length' "$jobs_jsonl")"
if [ "$exact_queue_available" = true ]; then
  codex_running=$((codex_running + exact_running_count))
fi
codex_queued="$(jq -s --arg regex "$codex_job_regex" '
def codex_job:
  (((.steps // []) | map(test("setup-codex"; "i")) | any) or
   ((.name // "") | test($regex; "i")) or
   (((.name // "") == "intake") and ((.run_name // "") | test("^repair commit finding intake$"; "i"))));
[.[] as $run
  | $run.jobs[]?
  | . + {run_name: $run.run_name}
  | select(.status == "queued" or .status == "waiting" or .status == "pending" or .status == "requested")
  | select(codex_job)
] | length' "$jobs_jsonl")"
job_query_failures="$(jq -s '[.[] | select(.query_failed)] | length' "$jobs_jsonl")"
job_query_failures=$((job_query_failures + unprobed_job_runs))
worker_capacity="$(jq -r '.workers.max | select(type == "number" and . > 0) // empty' "$limits_json")"
exact_capacity="$(jq -r '.lanes.exact_review.max_concurrent | select(type == "number" and . > 0) // empty' "$limits_json")"
exact_target_capacity="$(jq -r '.lanes.exact_review.target_max_concurrent | select(type == "number" and . > 0) // empty' "$limits_json")"
codex_running_display="$codex_running"
if [ -n "$worker_capacity" ]; then
  codex_running_display="${codex_running}/${worker_capacity}"
fi

echo "# ClawSweeper status"
echo
echo "Target: ${target_repo}"
echo "Window: last ${hours}h since ${since}"
echo
echo "## Workers"
echo
if [ "$run_query_failures" -gt 0 ] || [ "$run_query_truncated" -gt 0 ]; then
  printf -- "- Active workflow runs: at least %s (%s failed, %s truncated status queries)\n" "$active_count" "$run_query_failures" "$run_query_truncated"
else
  printf -- "- Active workflow runs: %s\n" "$active_count"
fi
if [ "$run_query_failures" -gt 0 ] || [ "$run_query_truncated" -gt 0 ]; then
  printf -- "- Queued/waiting workflow runs: at least %s\n" "$queued_count"
else
  printf -- "- Queued/waiting workflow runs: %s\n" "$queued_count"
fi
if [ "$run_query_failures" -gt 0 ] || [ "$run_query_truncated" -gt 0 ]; then
  printf -- "- Workflow concurrency waiters: at least %s\n" "$concurrency_waiters"
else
  printf -- "- Workflow concurrency waiters: %s\n" "$concurrency_waiters"
fi
if [ "$bad_run_query_failures" -gt 0 ] || [ "$bad_run_query_truncated" -gt 0 ]; then
  printf -- "- Failed/timed-out/action-required recent runs: at least %s (%s failed, %s truncated status queries)\n" "$bad_count" "$bad_run_query_failures" "$bad_run_query_truncated"
else
  printf -- "- Failed/timed-out/action-required recent runs: %s\n" "$bad_count"
fi
if [ "$job_query_failures" -gt 0 ] && { [ "$run_query_failures" -gt 0 ] || [ "$run_query_truncated" -gt 0 ]; }; then
  printf -- "- Active Codex jobs: at least %s running, at least %s queued (%s job queries unavailable; workflow status may be incomplete)\n" "$codex_running_display" "$codex_queued" "$job_query_failures"
elif [ "$job_query_failures" -gt 0 ]; then
  printf -- "- Active Codex jobs: at least %s running, at least %s queued (%s job queries unavailable)\n" "$codex_running_display" "$codex_queued" "$job_query_failures"
elif [ "$run_query_failures" -gt 0 ] || [ "$run_query_truncated" -gt 0 ]; then
  printf -- "- Active Codex jobs: at least %s running, at least %s queued (workflow status pages incomplete)\n" "$codex_running_display" "$codex_queued"
else
  printf -- "- Active Codex jobs: %s running, %s queued\n" "$codex_running_display" "$codex_queued"
fi
if [ "$exact_queue_available" = true ]; then
  exact_active="$exact_active_count"
  exact_pending="$(jq '.pending' "$exact_queue_json")"
  exact_active_display="$exact_active"
  if [ -n "$exact_capacity" ]; then
    exact_active_display="${exact_active}/${exact_capacity}"
  fi

  # Public aggregates omit private target occupancy; only an array can establish zero.
  if jq -e '.target_stats | type == "array"' "$exact_queue_json" >/dev/null; then
    target_exact_active="$(jq -r --arg target "$target_repo" '[.target_stats[]
      | select(.target_repo == $target)
      | ((.dispatching // 0) + (.leased // 0))][0] // 0' "$exact_queue_json")"
    target_exact_pending="$(jq -r --arg target "$target_repo" '[.target_stats[]
      | select(.target_repo == $target)
      | (.pending // 0)][0] // 0' "$exact_queue_json")"
    target_exact_active_display="$target_exact_active"
    if [ -n "$exact_target_capacity" ]; then
      target_exact_active_display="${target_exact_active}/${exact_target_capacity}"
    fi
    target_exact_display="${target_exact_active_display} active, ${target_exact_pending} pending"
  else
    target_exact_display="occupancy unavailable"
  fi
  printf -- "- Exact-review queue: %s active, %s pending (target %s: %s)\n" \
    "$exact_active_display" "$exact_pending" "$target_repo" "$target_exact_display"

  # Render directly: Bash read collapses empty TSV fields and shifts optional health data.
  jq -r '
    def count: if type == "number" then tostring else "unknown" end;
    def text: if type == "string" then . else "" end;
    def reason_line($label):
      if type == "object" then
        to_entries | map(select(.value | type == "number" and . > 0))
        | map("\(.key) \(.value)") | join(", ")
        | select(length > 0) | "- \($label): \(.)"
      else empty end;

    ("- Queue health: \((.handoff_health.status | text | select(length > 0)) // "unknown")" +
      (.handoff_health.reason | text | if length > 0 then " (\(.))" else "" end) +
      " — ready \(.ready_pending | count), admissible \(.admissible_pending | count)" +
      (if (.oldest_pending_age_seconds | type) == "number" then
        ", oldest pending " +
        (.oldest_pending_key | text | if length > 0 then . + " " else "" end) +
        "\(.oldest_pending_age_seconds / 60 | floor)m"
      elif (.oldest_pending_key | text | length) > 0 then
        ", oldest pending \(.oldest_pending_key) (age unknown)"
      else "" end)),
    (.lanes.review.backoff_reasons | reason_line("Queue backoff")),
    (.lanes.review.parked_reasons | reason_line("Queue parked (needs operator)")),
    (.shed_since_reset | select(type == "number" and . != 0) | "- Shed since reset: \(.)"),
    (if (.lanes.publication | type) == "object" then
      .lanes.publication |
      ("- Publication tail: \(.pending | count) pending, \(.ready | count) ready, " +
        "\(.backoff | count) backoff, \(.parked | count) parked, \(.active | count)" +
        (if (.capacity | type) == "number" then "/\(.capacity)" else "" end) + " active"),
      (.backoff_reasons | reason_line("Publication backoff")),
      (.parked_reasons | reason_line("Publication parked (needs operator)"))
    else "- Publication tail: unavailable" end)
  ' "$exact_queue_json"
else
  printf -- "- Exact-review queue: unavailable\n"
fi
echo
jq -r '[.workflow_runs[]
  | select(.status == "in_progress" or .status == "pending" or .status == "queued" or .status == "waiting" or .status == "requested")
] | group_by(.name) | sort_by(-length) | .[]
  | "- \((length))x \((.[0].name)): \((.[0].html_url))"' "$runs_json" | head -20

print_section() {
  local title="$1"
  local body="$2"
  echo
  echo "## ${title}"
  echo
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    echo "- none found in window"
  fi
}

merged="$(
  jq -r --arg since "$since" --argjson limit "$limit" '
    def one_line: gsub("[\r\n\t]+"; " ") | gsub("  +"; " ") | .[0:160];
    [.[] | select(.mergedAt != null and .mergedAt >= $since)
    ] | sort_by(.mergedAt) | reverse | .[0:$limit][]
    | "- \(.url) — \(.title | one_line) (merged \(.mergedAt))"
  ' "$pulls_json"
)"
print_section "Recently merged" "$merged"

reviewed="$(
  jq -r --arg bot "$bot_regex" --argjson limit "$limit" '
    def visible_line:
      split("\n")
      | map(gsub("[\r\t]+"; " ") | gsub("  +"; " ") | select(length > 0))
      | map(select(test("^<!--") | not))
      | (.[0] // "");
    def one_line: visible_line | .[0:180];
    [.[] | select((.user.login // "") | test($bot; "i"))
      | select((((.body // "") | test("clawsweeper-command-status"; "i"))) | not)
      | select((.body // "") | test("Codex review:|clawsweeper-action:review|ClawSweeper review"; "i"))
    ][0:$limit][]
    | "- \(.html_url) — #\(.issue_url | split("/")[-1]) \((.body // "") | one_line)"
  ' "$comments_json"
)"
print_section "Recently reviewed" "$reviewed"

commented="$(
  jq -r --arg bot "$bot_regex" --argjson limit "$limit" '
    def visible_line:
      split("\n")
      | map(gsub("[\r\t]+"; " ") | gsub("  +"; " ") | select(length > 0))
      | map(select(test("^<!--") | not))
      | (.[0] // "");
    def one_line: visible_line | .[0:180];
    [.[] | select((.user.login // "") | test($bot; "i"))
      | select((((.body // "") | test("Codex review:|clawsweeper-action:review|ClawSweeper review"; "i"))) | not)
    ][0:$limit][]
    | "- \(.html_url) — #\(.issue_url | split("/")[-1]) \((.body // "") | one_line)"
  ' "$comments_json"
)"
print_section "Recently commented" "$commented"

closed="$(
  jq -r --arg bot "$bot_regex" --arg since "$since" --argjson limit "$limit" '
    def one_line: gsub("[\r\n\t]+"; " ") | gsub("  +"; " ") | .[0:160];
    [((.data.pulls.nodes // []) + (.data.issues.nodes // []))[]
      | .timelineItems.nodes[0] as $event
      | select(.closedAt >= $since)
      | select(($event.actor.login // "") | test($bot; "i"))
      | {title, url, closed_at: .closedAt, actor: $event.actor.login}
    ] | sort_by(.closed_at) | reverse | .[0:$limit][]
    | "- \(.url) — \(.title | one_line) (closed by \(.actor) at \(.closed_at))"
  ' "$closed_items_json"
)"
print_section "Recently closed" "$closed"
