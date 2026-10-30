#!/usr/bin/env bash
# Tests for codex-resume with a stub `codex` on PATH. Run: bash codex-resume.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/codex-resume"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-resume-test.XXXXXX")" || exit 1
root="$(cd "$tmp" && pwd)" || exit 1
case "$root" in */codex-resume-test.*) ;; *) echo "refusing unexpected temp root: $root" >&2; exit 1 ;; esac
holder_pids=""
cleanup() { for p in $holder_pids; do kill "$p" 2>/dev/null; done; pkill -f "landing-marker $root" 2>/dev/null; rm -rf "$root"; }
trap cleanup EXIT

sid="01a1beef-0000-7000-8000-00000000c0de"
export CODEX_HOME="$root/codex-home" XDG_STATE_HOME="$root/state"
export CODEX_RESUME_BACKOFF=0 CODEX_RESUME_TRANSPORT_WAIT=0 CODEX_RESUME_STOP_GRACE=3
# lsof only scans processes with this command name (production: codex); holder tests override it.
export CODEX_RESUME_HOLDER=zzznomatch
mkdir -p "$CODEX_HOME/sessions/2026/10/14" "$root/wt" "$root/bin"
rollout="$CODEX_HOME/sessions/2026/10/14/rollout-2026-10-14T01-02-03-$sid.jsonl"
printf '{"timestamp":"2026-10-14T01:02:03Z","type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$sid" "$root/wt" > "$rollout"

cat > "$root/bin/codex" <<'EOF'
#!/usr/bin/env bash
# Stub: line N of $STUB/plan decides what invocation N prints and returns.
n=$(( $(cat "$STUB/argv" 2>/dev/null | wc -l) + 1 ))
printf '%s\n' "$*" >> "$STUB/argv"; pwd >> "$STUB/cwd"; cat > "$STUB/stdin.$n"
model=""; out=""; prev=""
for a in "$@"; do [ "$prev" = "-m" ] && model="$a"; [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
case "$(sed -n "${n}p" "$STUB/plan")" in
  ok) echo "session id: stub"; echo "final report" > "$out"; exit 0 ;;
  ratelimit) echo "ERROR: Reconnecting... 5/5"
    echo "ERROR: rate limit exceeded: Rate limit reached for $model in organization org-x on tokens per min (TPM)"
    for i in 1 2 3 4 5 6; do echo "ERROR codex_core::session: failed to record rollout items: thread x not found"; done; exit 1 ;;
  capacity) echo "ERROR: Selected model is at capacity. Please try a different model."; exit 1 ;;
  overloaded) echo "ERROR: The model is overloaded. Please retry."; exit 1 ;;
  writer) echo "Error: thread 01a1beef already has an active writer"; exit 1 ;;
  usage) echo "error: unexpected argument '-C' found"; echo "Usage: codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]"; exit 2 ;;
  listturns) echo "Error: thread/resume: thread/resume failed: list_turns is not supported yet (code -32601)"; exit 1 ;;
  transport) echo "ERROR: stream disconnected before completion"; exit 1 ;;
  toolnoise) echo "session id: stub"; echo "exec: pnpm foo -C bar"; echo "error: unexpected argument '-C' found"
    echo "Rate limit reached for gpt-test (from a test log)"; echo "Reconnecting... 2/5 (tool output)"
    echo "doc: list_turns is not supported yet"; echo "doc: Selected model is at capacity"; exit 1 ;;
  *) echo "something unexpected"; exit 1 ;;
esac
EOF
chmod +x "$root/bin/codex"
export PATH="$root/bin:$PATH"

pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
setup() { export STUB="$root/stub-$1"; rm -rf "$STUB"; mkdir -p "$STUB"; shift; printf '%s\n' "$@" > "$STUB/plan"; }
run() { "$script" "$@" > "$STUB/stdout" 2> "$STUB/stderr"; rc=$?; }
calls() { cat "$STUB/argv" 2>/dev/null | wc -l | tr -d ' '; }
argv() { sed -n "${1}p" "$STUB/argv"; }

setup dry ok; run --dry-run "$sid"
check "dry-run exits 0" '[ "$rc" -eq 0 ]'
check "dry-run resolves cwd from session_meta" 'grep -q "cwd      $root/wt" "$STUB/stdout"'
check "dry-run runs nothing" '[ "$(calls)" -eq 0 ]'

setup ok ok; run --message "decision: land it" "$sid"
check "ok exits 0" '[ "$rc" -eq 0 ]'
check "resume flags, no -C" 'argv 1 | grep -q "^exec resume $sid --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m gpt-6.1-sol -c model_reasoning_effort=\"high\" --enable fast_mode -c service_tier=\"fast\" -o " && ! argv 1 | grep -q -- " -C "'
check "runs in the recorded cwd" '[ "$(sed -n 1p "$STUB/cwd")" = "$root/wt" ]'
check "sends the follow-up" 'grep -q "decision: land it" "$STUB/stdin.1"'
check "writes the final message" 'grep -q "final report" "$XDG_STATE_HOME/codex-first/$sid/last-message.md"'

setup fallback ratelimit ok; run --message "decision: land it" "$sid"
check "rate limit then ok exits 0" '[ "$rc" -eq 0 ]'
check "falls back to astra fast" 'argv 2 | grep -q "\-m gpt-6-astra .*service_tier=\"fast\""'
check "retry sends continue, not the follow-up again" 'grep -q "rate-limit or transport" "$STUB/stdin.2" && ! grep -q "decision" "$STUB/stdin.2"'

setup flipback ratelimit capacity ok; run "$sid"
check "both limited then ok exits 0" '[ "$rc" -eq 0 ]'
check "returns to sol fast after astra limit" 'argv 3 | grep -q "\-m gpt-6.1-sol .*service_tier=\"fast\""'

setup start-astra ratelimit ok; run --model gpt-6-astra --tier ultrafast "$sid"
check "requested ultrafast keeps the 260k compact cap" 'argv 1 | grep -q "\-m gpt-6-astra .*service_tier=\"ultrafast\" -c model_auto_compact_token_limit=260000 -o "'
check "astra start falls back to sol" 'argv 2 | grep -q "\-m gpt-6.1-sol .*service_tier=\"fast\" -o "'

setup overloaded overloaded ok; run "$sid"
check "overloaded switches models" '[ "$rc" -eq 0 ] && argv 2 | grep -q "\-m gpt-6-astra"'

setup writer writer ok; run "$sid"
check "active-writer refusal exits 4" '[ "$rc" -eq 4 ] && [ "$(calls)" -eq 1 ]'

setup usage usage ok; run "$sid"
check "flag rejection exits 2 without retry" '[ "$rc" -eq 2 ] && [ "$(calls)" -eq 1 ]'

setup listturns listturns ok; run "$sid"
check "refused resume exits 3" '[ "$rc" -eq 3 ] && grep -q "relaunch fresh" "$STUB/stderr"'

setup transport transport ok; run "$sid"
check "transport retry keeps the model" '[ "$rc" -eq 0 ] && argv 2 | grep -q "\-m gpt-6.1-sol"'

setup toolnoise toolnoise ok; run "$sid"
check "tool output that mimics codex errors stays unclassified" '[ "$rc" -eq 1 ] && [ "$(calls)" -eq 1 ]'

setup unknown weird ok; run "$sid"
check "unclassified failure exits 1 without retry" '[ "$rc" -eq 1 ] && [ "$(calls)" -eq 1 ]'

setup maxed ratelimit ratelimit ratelimit ok; run --max-attempts 3 "$sid"
check "gives up after max attempts" '[ "$rc" -eq 1 ] && [ "$(calls)" -eq 3 ]'

setup fromlog ok; printf 'OpenAI Codex\nsession id: %s\n' "$sid" > "$root/old.log"; run "$root/old.log"
check "session id from a log file" '[ "$rc" -eq 0 ] && argv 1 | grep -q "resume $sid"'

setup nolog ok; printf 'Updating files\n' > "$root/empty.log"; run "$root/empty.log"
check "log without session id exits 3" '[ "$rc" -eq 3 ]'

setup missing ok; run "01a1beef-0000-7000-8000-000000000bad"
check "unknown session exits 3" '[ "$rc" -eq 3 ]'

setup badprompt ok; run --stop -p "$root/no-such-order.md" "$sid"
check "unreadable prompt fails before anything runs" '[ "$rc" -eq 2 ] && [ "$(calls)" -eq 0 ]'

setup badopt ok; run --bogus "$sid"
check "unknown option exits 2" '[ "$rc" -eq 2 ]'

# A live holder of the rollout file stands in for a running codex worker.
bash -c 'exec 3>>"$1"; exec sleep 60' _ "$rollout" & holder=$!; holder_pids="$holder_pids $holder"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(lsof -t "$rollout" 2>/dev/null)" ] && break; sleep 0.3; done
export CODEX_RESUME_HOLDER=sleep
setup busy ok; run "$sid"
check "live session without --stop exits 4" '[ "$rc" -eq 4 ] && [ "$(calls)" -eq 0 ]'
setup stop ok; run --stop "$sid"
check "--stop ends the holder and resumes" '[ "$rc" -eq 0 ] && ! kill -0 "$holder" 2>/dev/null && [ "$(calls)" -eq 1 ]'

# Like codex: the holder (bash) runs the landing command as a descendant.
bash -c 'exec 3>>"$1"; sh -c "sleep 60; : scripts/pr merge-run landing-marker $2"; true' _ "$rollout" "$root" & holder=$!
export CODEX_RESUME_HOLDER=bash; holder_pids="$holder_pids $holder"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(lsof -t "$rollout" 2>/dev/null)" ] && break; sleep 0.3; done
setup landing ok; run --stop "$sid"
check "--stop refuses while scripts/pr runs" '[ "$rc" -eq 5 ] && kill -0 "$holder" 2>/dev/null && grep -q "scripts/pr" "$STUB/stderr"'
setup forced ok; run --stop --force "$sid"
check "--stop --force stops anyway" '[ "$rc" -eq 0 ] && [ "$(calls)" -eq 1 ]'

bash -c 'exec 3>>"$1"; sh -c "sleep 60; : git -C /some/wt rebase origin/main landing-marker $2"; true' _ "$rollout" "$root" & holder=$!; holder_pids="$holder_pids $holder"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(lsof -nP -t -a -c bash "$rollout" 2>/dev/null)" ] && break; sleep 0.3; done
setup gitc ok; run --stop "$sid"
check "--stop refuses git with global options" '[ "$rc" -eq 5 ] && kill -0 "$holder" 2>/dev/null'
kill "$holder" 2>/dev/null; pkill -f "landing-marker $root" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(lsof -nP -t -a -c bash "$rollout" 2>/dev/null)" ] && break; sleep 0.3; done

export CODEX_RESUME_HOLDER=zzznomatch
mkdir -p "$root/caller"
setup relout ok; (cd "$root/caller" && "$script" -o rel/out.md "$sid" > "$STUB/stdout" 2> "$STUB/stderr"); rc=$?
check "relative -o resolves against the caller" '[ "$rc" -eq 0 ] && grep -q "final report" "$root/caller/rel/out.md" && ls "$root/caller/rel"/resume-*-1.log >/dev/null 2>&1'

echo "codex-resume tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
