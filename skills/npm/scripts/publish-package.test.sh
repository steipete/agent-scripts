#!/usr/bin/env bash
# Drives publish-package.sh through a local npm stand-in. No registry or 1Password.
set -euo pipefail

TEST_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/npm-publish-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/package"
printf '%s\n' '{"name":"@example/restricted-proof","version":"1.2.3"}' >"$TEST_ROOT/package/package.json"

cat >"$TEST_ROOT/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="${PUBLISH_TEST_ROOT:?}"
mode="${PUBLISH_TEST_MODE:?}"
printf 'cmd=%s userconfig=%s\n' "$1" "${NPM_CONFIG_USERCONFIG:-}" >>"$root/npm-calls"
case "$1" in
  whoami)
    if [ -z "${NPM_CONFIG_USERCONFIG:-}" ]; then
      echo "whoami without npmrc" >&2
      exit 1
    fi
    printf 'synthetictest\n'
    ;;
  view)
    if [ "$mode" = "public-existing" ]; then
      printf '1.2.3\n'
      exit 0
    fi
    if [ -z "${NPM_CONFIG_USERCONFIG:-}" ]; then
      exit 1
    fi
    if [ "$mode" = "restricted-existing" ]; then
      printf '1.2.3\n'
      exit 0
    fi
    if [ "$mode" = "restricted-new" ] && [ -f "$root/published" ]; then
      printf '1.2.3\n'
      exit 0
    fi
    exit 1
    ;;
  publish)
    if [ -z "${NPM_CONFIG_USERCONFIG:-}" ] || [ -z "${NPM_CONFIG_OTP:-}" ]; then
      echo "publish missing registry auth" >&2
      exit 1
    fi
    printf 'published\n' >"$root/published"
    ;;
  *)
    echo "unexpected npm command: $1" >&2
    exit 98
    ;;
esac
EOF

cat >"$TEST_ROOT/bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "${PUBLISH_TEST_ROOT:?}/op-called"
if [ "${1:-}" = "item" ] && [ "${2:-}" = "get" ]; then
  joined=" $* "
  case "$joined" in
    *" --otp "*)
      printf '123456\n'
      exit 0
      ;;
  esac
  cat <<'JSON'
{"fields":[{"label":"registry_token","type":"CONCEALED","value":"synthetic-registry-token"}]}
JSON
  exit 0
fi
echo "unexpected op invocation" >&2
exit 98
EOF

cat >"$TEST_ROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/npm" "$TEST_ROOT/bin/op" "$TEST_ROOT/bin/sleep"

run_case() {
  local mode="$1"
  local log="$TEST_ROOT/$mode"
  rm -f "$TEST_ROOT/npm-calls" "$TEST_ROOT/op-called" "$TEST_ROOT/published"
  : >"$TEST_ROOT/npm-calls"
  set +e
  (
    cd "$TEST_ROOT/package"
    PUBLISH_TEST_MODE="$mode" \
      PUBLISH_TEST_ROOT="$TEST_ROOT" \
      OP_SERVICE_ACCOUNT_TOKEN=synthetic-op-token \
      TMUX=test-session \
      PATH="$TEST_ROOT/bin:$PATH" \
      /bin/bash "$TEST_SCRIPT_DIR/publish-package.sh" >"$log.out" 2>"$log.err"
  )
  local exit_code=$?
  set -e
  printf '%s\n' "$exit_code" >"$log.exit"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F -q -- "$needle" "$file"; then
    echo "missing [$needle] in $file" >&2
    echo "----- $file -----" >&2
    cat "$file" >&2
    exit 1
  fi
}

run_case public-existing
test "$(cat "$TEST_ROOT/public-existing.exit")" = "5"
assert_file_contains "$TEST_ROOT/public-existing.err" "@example/restricted-proof@1.2.3 is already published"
test ! -e "$TEST_ROOT/op-called"
if grep -F -q 'cmd=publish' "$TEST_ROOT/npm-calls"; then
  echo "public package that is already visible must not publish" >&2
  exit 1
fi
echo "ok 1 - public version is refused before 1Password"

run_case restricted-existing
if [ "$(cat "$TEST_ROOT/restricted-existing.exit")" != "5" ]; then
  echo "restricted existing exited $(cat "$TEST_ROOT/restricted-existing.exit"), expected 5" >&2
  echo "----- stderr -----" >&2
  cat "$TEST_ROOT/restricted-existing.err" >&2
  echo "----- npm calls -----" >&2
  cat "$TEST_ROOT/npm-calls" >&2
  exit 1
fi
assert_file_contains "$TEST_ROOT/restricted-existing.err" "@example/restricted-proof@1.2.3 is already published"
if grep -F -q 'cmd=publish' "$TEST_ROOT/npm-calls"; then
  echo "restricted package that already exists must not publish again" >&2
  cat "$TEST_ROOT/npm-calls" >&2
  exit 1
fi
if ! grep -F -q 'cmd=view userconfig=/tmp/' "$TEST_ROOT/npm-calls" && ! grep -E -q 'cmd=view userconfig=.+/npmrc$' "$TEST_ROOT/npm-calls"; then
  echo "restricted pre-check did not use the temporary npmrc" >&2
  cat "$TEST_ROOT/npm-calls" >&2
  exit 1
fi
echo "ok 2 - restricted existing version is visible through the temporary npmrc"

run_case restricted-new
if [ "$(cat "$TEST_ROOT/restricted-new.exit")" != "0" ]; then
  echo "restricted new exited $(cat "$TEST_ROOT/restricted-new.exit"), expected 0" >&2
  echo "----- stdout -----" >&2
  cat "$TEST_ROOT/restricted-new.out" >&2
  echo "----- stderr -----" >&2
  cat "$TEST_ROOT/restricted-new.err" >&2
  echo "----- npm calls -----" >&2
  cat "$TEST_ROOT/npm-calls" >&2
  exit 1
fi
assert_file_contains "$TEST_ROOT/restricted-new.out" "registry version verified: @example/restricted-proof@1.2.3"
test -f "$TEST_ROOT/published"
view_after_publish="$(awk '
  $1 == "cmd=publish" { seen = 1; next }
  seen && $1 == "cmd=view" && $2 ~ /^userconfig=\// { print; exit }
' "$TEST_ROOT/npm-calls")"
if [ -z "$view_after_publish" ]; then
  echo "post-publish view did not use the temporary npmrc" >&2
  cat "$TEST_ROOT/npm-calls" >&2
  exit 1
fi
echo "ok 3 - restricted publish is verified with the temporary npmrc"

echo "publish-package registry visibility: 3 checks passed"
