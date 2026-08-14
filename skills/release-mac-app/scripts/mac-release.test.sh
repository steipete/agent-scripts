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
  *" display-message "*) printf '999999\n' ;;
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
    sparkle_path_line=$(sed -n 's/^export MAC_RELEASE_SPARKLE_KEY_FILE=//p' "$runner_path" | tail -1)
    if [[ -n "$sparkle_path_line" ]]; then
      eval "sparkle_path=$sparkle_path_line"
      [[ -z "$sparkle_path" ]] || printf '%s\n' "$sparkle_path" >"$MAC_RELEASE_TEST_ROOT/last-sparkle-path"
    fi
    ;;
  *" kill-window "*)
    if [[ -f "$MAC_RELEASE_TEST_ROOT/last-sparkle-path" ]]; then
      sparkle_path=$(<"$MAC_RELEASE_TEST_ROOT/last-sparkle-path")
      [[ -z "$sparkle_path" || -f "$sparkle_path" ]] || {
        echo 'Sparkle temp key was removed before its tmux producer stopped' >&2
        exit 1
      }
    fi
    ;;
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
  if [[ "$2" == "op://Release/Test Sparkle Key/private key" ]]; then
    printf '%s\n' "${MAC_RELEASE_TEST_SPARKLE_KEY:?}"
  else
    printf '%s\n' 'ref-value'
  fi
else
  echo "unexpected op call" >&2
  exit 1
fi
OP
chmod +x "$test_root/bin/op"

cat >"$test_root/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
set -euo pipefail
key_file=${2:?key file}
[[ -f "$key_file" ]]
[[ "$(<"$key_file")" == "${MAC_RELEASE_TEST_SPARKLE_KEY:?}" ]]
printf '%s\n' 'test-public-key'
SWIFT
chmod +x "$test_root/bin/swift"

cat >"$test_root/bin/sign_update" <<'SIGN_UPDATE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--ed-key-file" ]]
key_file=$2
[[ -f "$key_file" ]]
[[ "$(<"$key_file")" == "${MAC_RELEASE_TEST_SPARKLE_KEY:?}" ]]
SIGN_UPDATE
chmod +x "$test_root/bin/sign_update"

# shellcheck source=lib/mac_release.sh
source "$script_dir/lib/mac_release.sh"

service_token='service-token-that-must-never-appear'
sparkle_test_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
service_output="$test_root/service.output"
(
  trap - EXIT
  export PATH="$test_root/bin:$PATH"
  export MAC_RELEASE_TEST_ROOT="$test_root"
  export MAC_RELEASE_TEST_MODE=service
  export MAC_RELEASE_TEST_TOKEN="$service_token"
  export MAC_RELEASE_TEST_SPARKLE_KEY="$sparkle_test_key"
  export OP_SERVICE_ACCOUNT_TOKEN="$service_token"
  export MAC_RELEASE_OP_ITEM='Release credentials'
  export MAC_RELEASE_OP_FIELDS=TEST_SECRET
  export MAC_RELEASE_OP_ACCOUNT=test.1password.example
  export MAC_RELEASE_OP_USE_SERVICE_ACCOUNT=1
  export MAC_RELEASE_OP_VAULT=Molty
  export MAC_RELEASE_OP_ENV_REFS='EXTRA_SECRET=op://Molty/Release credentials/extra'
  export MAC_RELEASE_SPARKLE_OP_REF='op://Release/Test Sparkle Key/private key'
  export MAC_RELEASE_SPARKLE_OP_USE_SERVICE_ACCOUNT=1
  export MAC_RELEASE_CODESIGN_OP_ITEM='Signing keychain'
  unset MAC_RELEASE_CODESIGN_OP_VAULT

  mac_release_load_1password_env
  [[ "$TEST_SECRET" == "loaded-value" ]]
  [[ "$EXTRA_SECRET" == "ref-value" ]]
  [[ "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "/tmp/release.keychain-db" ]]
  [[ "$MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD" == "password-value" ]]
  resolved_sparkle_key=$SPARKLE_PRIVATE_KEY_FILE
  [[ -f "$resolved_sparkle_key" ]]
  sparkle_mode=$(stat -f '%Lp' "$resolved_sparkle_key" 2>/dev/null || stat -c '%a' "$resolved_sparkle_key")
  [[ "$sparkle_mode" == "600" ]]
  [[ "$(<"$resolved_sparkle_key")" == "$sparkle_test_key" ]]

  # shellcheck disable=SC2329 # invoked indirectly by mac_release_key_args_and_validate
  mac_release_expected_public_key() { printf '%s\n' 'test-public-key'; }
  KEY_ARGS=()
  sparkle_key_file=
  mac_release_key_args_and_validate KEY_ARGS sparkle_key_file
  [[ "${KEY_ARGS[0]}" == "--ed-key-file" ]]
  [[ "${KEY_ARGS[1]}" == "$sparkle_key_file" ]]
  [[ -f "$sparkle_key_file" ]]
  [[ ! -e "$resolved_sparkle_key" ]]
  cleaned_mode=$(stat -f '%Lp' "$sparkle_key_file" 2>/dev/null || stat -c '%a' "$sparkle_key_file")
  [[ "$cleaned_mode" == "600" ]]
  [[ "$_MAC_RELEASE_OWNED_SPARKLE_CLEAN_FILE" == "$sparkle_key_file" ]]
  [[ "$(bash -c 'printf %s "${_MAC_RELEASE_OWNED_SPARKLE_RAW_FILE:-unset}:${_MAC_RELEASE_OWNED_SPARKLE_CLEAN_FILE:-unset}"')" == unset:unset ]]
  rm -f "$sparkle_key_file"
  _MAC_RELEASE_OWNED_SPARKLE_CLEAN_FILE=

  export MAC_RELEASE_TEST_SPARKLE_KEY=$'invalid\nmultiline'
  unset SPARKLE_PRIVATE_KEY_FILE
  _MAC_RELEASE_OWNED_SPARKLE_RAW_FILE=
  _MAC_RELEASE_OWNED_SPARKLE_CLEAN_FILE=
  (
    # shellcheck disable=SC2329 # invoked by mac_release_sparkle_key_status
    mac_release_load() { :; }
    if mac_release_sparkle_key_status; then
      echo 'malformed Sparkle status key unexpectedly validated' >&2
      exit 1
    fi
  )
  malformed_status_key=$(<"$test_root/last-sparkle-path")
  [[ ! -e "$malformed_status_key" ]]

  parent_owned_key=$(mktemp /tmp/mac-release-sparkle-parent-test.XXXXXX)
  printf '%s\n%s\n' invalid multiline >"$parent_owned_key"
  export SPARKLE_PRIVATE_KEY_FILE=$parent_owned_key
  _MAC_RELEASE_OWNED_SPARKLE_RAW_FILE=$parent_owned_key
  (
    # shellcheck disable=SC2329 # invoked by mac_release_sparkle_key_status
    mac_release_load() { :; }
    if mac_release_sparkle_key_status; then
      echo 'parent-owned malformed Sparkle key unexpectedly validated' >&2
      exit 1
    fi
  )
  [[ -f "$parent_owned_key" ]]
  rm -f "$parent_owned_key"
  _MAC_RELEASE_OWNED_SPARKLE_RAW_FILE=
) >"$service_output" 2>&1

grep -Fq 'has-session' "$test_root/tmux.log"
[[ "$(grep -c 'new-window' "$test_root/tmux.log")" == "2" ]]
if grep -Fq 'new-session' "$test_root/tmux.log"; then
  echo "pre-existing op-work session was replaced" >&2
  exit 1
fi
[[ "$(grep -c '^mode=service ' "$test_root/op.log")" == "5" ]]
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
if grep -Fq "$sparkle_test_key" "$service_output" "$test_root/tmux.log" "$test_root/op.log"; then
  echo "Sparkle private key was disclosed" >&2
  exit 1
fi

: >"$test_root/tmux.log"
: >"$test_root/op.log"
rm -f "$test_root/last-sparkle-path"
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
