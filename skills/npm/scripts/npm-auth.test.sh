#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d /tmp/npm-auth-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

WORK="$TEST_ROOT/work"
NPMRC="$WORK/npmrc"
REGISTRY="https://registry.npmjs.org/"
mkdir -p "$WORK" "$TEST_ROOT/bin" "$TEST_ROOT/caller"
printf '%s\n' '//registry.npmjs.org/:_authToken=fresh-token' >"$NPMRC"
printf '%s\n' '//registry.npmjs.org/:_authToken=stale-token' >"$TEST_ROOT/caller/.npmrc"

cat >"$TEST_ROOT/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$PWD" = "$EXPECTED_PWD"
test "$NPM_CONFIG_USERCONFIG" = "$EXPECTED_NPMRC"
test "$NPM_CONFIG_REGISTRY" = "https://registry.npmjs.org/"
if env | grep -Fq 'npm_config_//registry.npmjs.org/:_authToken='; then
  echo "npm token leaked into environment" >&2
  exit 1
fi
test "$#" = "1"
test "$1" = "whoami"
printf 'steipete\n'
EOF
chmod +x "$TEST_ROOT/bin/npm"

# shellcheck source=npm-auth.sh
source "$SCRIPT_DIR/npm-auth.sh"

result="$(
  cd "$TEST_ROOT/caller"
  EXPECTED_PWD="$WORK" EXPECTED_NPMRC="$NPMRC" PATH="$TEST_ROOT/bin:$PATH" npm_auth_whoami
)"
test "$result" = "steipete"

ITEM_JSON='{"fields":[{"label":"username","value":"owner"},{"label":"registry_token","type":"CONCEALED","value":"stale-token"}]}'
op_item_edit_json() {
  cat >"$TEST_ROOT/updated-item.json"
}
op_item_get() {
  cat "$TEST_ROOT/updated-item.json"
}
cache_output="$(persist_registry_token)"
test "$cache_output" = "npm auth: cached registry session in 1Password"
node -e '
const fs = require("fs");
const item = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const token = item.fields.find(field => field.label === "registry_token");
if (token?.value !== "fresh-token" || token?.type !== "CONCEALED") process.exit(1);
' "$TEST_ROOT/updated-item.json"

echo "npm auth isolation and token handling: ok"
