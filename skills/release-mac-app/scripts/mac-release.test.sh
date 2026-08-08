#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d /tmp/mac-release-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
printf '%s\n' 'pane-input' 'pane-input' >"$test_root/pane-input"

cat >"$test_root/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${MAC_RELEASE_TEST_ROOT:?}/tmux.log"
printf '\n' >>"$MAC_RELEASE_TEST_ROOT/tmux.log"

case " $* " in
  *" has-session "*) exit 0 ;;
  *" new-session "*)
    echo "unexpected new tmux session" >&2
    exit 1
    ;;
  *" new-window "*) printf '@7\n' ;;
  *" send-keys "*)
    command_text=
    previous=
    for arg in "$@"; do
      if [[ "$previous" == "--" ]]; then
        command_text=$arg
        break
      fi
      previous=$arg
    done
    [[ -n "$command_text" ]]
    runner_path=${command_text#* bash }
    runner_path=${runner_path%%;*}
    [[ -f "$runner_path" ]]
    work_dir=${runner_path%/*}
    if grep -Fq "${MAC_RELEASE_TEST_TOKEN:?}" "$command_text" "$runner_path" "$work_dir/read-op.sh"; then
      echo "service-account token appeared in tmux command or generated script" >&2
      exit 1
    fi
    if [[ "$MAC_RELEASE_TEST_MODE" == "service" ]]; then
      token_file="$work_dir/service-account-token"
      [[ -f "$token_file" ]]
      token_mode=$(stat -f '%Lp' "$token_file" 2>/dev/null || stat -c '%a' "$token_file")
      [[ "$token_mode" == "600" ]]
      [[ "$(<"$token_file")" == "$MAC_RELEASE_TEST_TOKEN" ]]
    else
      [[ ! -e "$work_dir/service-account-token" ]]
    fi
    env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
      bash --noprofile --norc -c "$command_text" <"$MAC_RELEASE_TEST_ROOT/pane-input"
    [[ ! -e "$work_dir/service-account-token" ]]
    ;;
  *" kill-window "*) ;;
  *)
    echo "unexpected tmux call" >&2
    exit 1
    ;;
esac
TMUX
chmod +x "$test_root/bin/tmux"

cat >"$test_root/bin/op" <<'OP'
#!/usr/bin/env bash
set -euo pipefail

has_account=0
for arg in "$@"; do
  [[ "$arg" != "--account" ]] || has_account=1
done

case "${MAC_RELEASE_TEST_MODE:?}" in
  service)
    [[ "${OP_LOAD_DESKTOP_APP_SETTINGS:-}" == "false" ]]
    [[ "${OP_BIOMETRIC_UNLOCK_ENABLED:-}" == "false" ]]
    [[ "${OP_SERVICE_ACCOUNT_TOKEN:-}" == "${MAC_RELEASE_TEST_TOKEN:?}" ]]
    [[ "$has_account" == "0" ]]
    if IFS= read -r pane_input; then
      echo "service-account op command read from the pane: $pane_input" >&2
      exit 1
    fi
    ;;
  interactive)
    [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]
    [[ -z "${MOLTY_OP_SERVICE_ACCOUNT_TOKEN:-}" ]]
    [[ -z "${OP_LOAD_DESKTOP_APP_SETTINGS:-}" ]]
    [[ -z "${OP_BIOMETRIC_UNLOCK_ENABLED:-}" ]]
    [[ "$has_account" == "1" ]]
    [[ " $* " == *" --account test.1password.example "* ]]
    IFS= read -r pane_input
    [[ "$pane_input" == "pane-input" ]]
    ;;
  *) exit 1 ;;
esac

printf 'mode=%s load=%s biometric=%s account=%s args=' \
  "$MAC_RELEASE_TEST_MODE" \
  "${OP_LOAD_DESKTOP_APP_SETTINGS:-unset}" \
  "${OP_BIOMETRIC_UNLOCK_ENABLED:-unset}" \
  "$has_account" >>"${MAC_RELEASE_TEST_ROOT:?}/op.log"
printf '%q ' "$@" >>"$MAC_RELEASE_TEST_ROOT/op.log"
printf '\n' >>"$MAC_RELEASE_TEST_ROOT/op.log"

if [[ "$1 $2" == "item get" ]]; then
  printf '%s\n' '{"fields":[{"label":"TEST_SECRET","value":"loaded-value"},{"label":"keychain_path","value":"/tmp/release.keychain-db"},{"label":"keychain_password","value":"password-value"}]}'
elif [[ "$1" == "read" ]]; then
  printf '%s\n' 'ref-value'
else
  echo "unexpected op call" >&2
  exit 1
fi
OP
chmod +x "$test_root/bin/op"

# shellcheck source=lib/mac_release.sh
source "$script_dir/lib/mac_release.sh"

service_token='service-token-that-must-never-appear'
service_output="$test_root/service.output"
(
  trap - EXIT
  export PATH="$test_root/bin:$PATH"
  export MAC_RELEASE_TEST_ROOT="$test_root"
  export MAC_RELEASE_TEST_MODE=service
  export MAC_RELEASE_TEST_TOKEN="$service_token"
  export OP_SERVICE_ACCOUNT_TOKEN="$service_token"
  export MAC_RELEASE_OP_ITEM='Release credentials'
  export MAC_RELEASE_OP_FIELDS=TEST_SECRET
  export MAC_RELEASE_OP_ACCOUNT=test.1password.example
  export MAC_RELEASE_OP_USE_SERVICE_ACCOUNT=1
  export MAC_RELEASE_OP_VAULT=Molty
  export MAC_RELEASE_OP_ENV_REFS='EXTRA_SECRET=op://Molty/Release credentials/extra'
  export MAC_RELEASE_CODESIGN_OP_ITEM='Signing keychain'
  unset MAC_RELEASE_CODESIGN_OP_VAULT

  mac_release_load_1password_env
  [[ "$TEST_SECRET" == "loaded-value" ]]
  [[ "$EXTRA_SECRET" == "ref-value" ]]
  [[ "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "/tmp/release.keychain-db" ]]
  [[ "$MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD" == "password-value" ]]
) >"$service_output" 2>&1

grep -Fq 'has-session' "$test_root/tmux.log"
[[ "$(grep -c 'new-window' "$test_root/tmux.log")" == "1" ]]
if grep -Fq 'new-session' "$test_root/tmux.log"; then
  echo "pre-existing op-work session was replaced" >&2
  exit 1
fi
[[ "$(grep -c '^mode=service ' "$test_root/op.log")" == "3" ]]
if grep -Fq -- '--account' "$test_root/op.log"; then
  echo "service-account op command included --account" >&2
  exit 1
fi
grep -Fq 'load=false biometric=false account=0' "$test_root/op.log"
[[ "$(grep -c -- '--vault Molty' "$test_root/op.log")" == "2" ]]
if grep -Fq "$service_token" "$service_output" "$test_root/tmux.log" "$test_root/op.log"; then
  echo "service-account token was disclosed" >&2
  exit 1
fi

: >"$test_root/tmux.log"
: >"$test_root/op.log"
interactive_output="$test_root/interactive.output"
(
  trap - EXIT
  export PATH="$test_root/bin:$PATH"
  export MAC_RELEASE_TEST_ROOT="$test_root"
  export MAC_RELEASE_TEST_MODE=interactive
  export MAC_RELEASE_TEST_TOKEN="$service_token"
  unset OP_SERVICE_ACCOUNT_TOKEN
  export MOLTY_OP_SERVICE_ACCOUNT_TOKEN='legacy-token-that-must-not-be-used'
  export OP_LOAD_DESKTOP_APP_SETTINGS=false
  export OP_BIOMETRIC_UNLOCK_ENABLED=false
  export MAC_RELEASE_OP_ITEM='Personal release credentials'
  export MAC_RELEASE_OP_FIELDS=TEST_SECRET
  export MAC_RELEASE_OP_ACCOUNT=test.1password.example
  export MAC_RELEASE_OP_USE_SERVICE_ACCOUNT=0
  export MAC_RELEASE_OP_VAULT=Private
  export MAC_RELEASE_OP_ENV_REFS='EXTRA_SECRET=op://Private/Personal release credentials/extra'
  unset MAC_RELEASE_CODESIGN_OP_ITEM

  mac_release_load_1password_env
  [[ "$TEST_SECRET" == "loaded-value" ]]
  [[ "$EXTRA_SECRET" == "ref-value" ]]
) >"$interactive_output" 2>&1

[[ "$(grep -c '^mode=interactive ' "$test_root/op.log")" == "2" ]]
grep -Fq 'mode=interactive load=unset biometric=unset account=1' "$test_root/op.log"
grep -Fq -- '--account test.1password.example' "$test_root/op.log"
grep -Fq -- '--vault Private' "$test_root/op.log"
if grep -Fq "$service_token" "$interactive_output" "$test_root/tmux.log" "$test_root/op.log"; then
  echo "ambient service-account token was disclosed by desktop flow" >&2
  exit 1
fi

echo "mac release 1Password tests passed"
