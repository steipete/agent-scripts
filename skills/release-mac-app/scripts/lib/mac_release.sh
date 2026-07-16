#!/usr/bin/env bash

mac_release_die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || mac_release_die "Missing required tool: $b"
  done
}

mac_release_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

mac_release_expand() {
  local value=${1:-}
  eval "printf '%s' \"$value\""
}

mac_release_expand_home_path() {
  local value=${1:-}
  if [[ $value == \~/* ]]; then
    printf '%s/%s' "$HOME" "${value#\~/}"
  elif [[ $value == \$HOME/* ]]; then
    printf '%s/%s' "$HOME" "${value#\$HOME/}"
  else
    printf '%s' "$value"
  fi
}

mac_release_sparkle_account_args() {
  local out_var=${1:?"out var"} account
  account=${MAC_RELEASE_SPARKLE_ACCOUNT:-${SPARKLE_ACCOUNT:-}}
  if [[ -n "$account" ]]; then
    eval "$out_var=(--account \"\$account\")"
  else
    eval "$out_var=()"
  fi
}

mac_release_tmux_quote() {
  local out
  printf -v out '%q' "$1"
  printf '%s' "$out"
}

mac_release_load_1password_env() {
  set +vx
  local mode=${1:-all} codesign_passwordless=${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}
  local primary_missing=0 codesign_missing=0 release_op_field
  [[ "$mode" == "all" || "$mode" == "codesign-only" ]] ||
    mac_release_die "Unknown 1Password load mode: $mode"
  if [[ "$codesign_passwordless" == "1" ]]; then
    unset MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  elif [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    export -n MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  fi
  if [[ "$mode" == "all" && -n "${MAC_RELEASE_OP_ITEM:-}" ]]; then
    [[ -n "${MAC_RELEASE_OP_FIELDS:-}" ]] || mac_release_die "Set MAC_RELEASE_OP_FIELDS with MAC_RELEASE_OP_ITEM"
    for release_op_field in $MAC_RELEASE_OP_FIELDS; do
      [[ -n "${!release_op_field:-}" ]] || primary_missing=1
    done
  fi
  if [[ -n "${MAC_RELEASE_CODESIGN_OP_ITEM:-}" ]]; then
    [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" ]] || codesign_missing=1
    if [[ "$codesign_passwordless" != "1" ]]; then
      [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]] || codesign_missing=1
    fi
  fi
  if [[ "$primary_missing" != "1" && "$codesign_missing" != "1" ]]; then
    if [[ "$mode" == "all" ]]; then
      for release_op_field in ${MAC_RELEASE_OP_FIELDS:-}; do
        export "${release_op_field?}"
      done
    fi
    if [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]]; then
      export -n MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
    fi
    [[ -z "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" ]] || export MAC_RELEASE_CODESIGN_KEYCHAIN
    return 0
  fi

  require_bin tmux op node
  local account vault socket_dir socket session op_window work_dir script runner env_file log_file status_file
  account=${MAC_RELEASE_OP_ACCOUNT:-my.1password.com}
  vault=${MAC_RELEASE_OP_VAULT:-}
  socket_dir=${CLAWDBOT_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/clawdbot-tmux-sockets}
  mkdir -p "$socket_dir"
  # Shared op tmux server/session (see one-password skill): every op flow uses
  # clawdbot-op.sock + op-work and its own window; extra sessions alert Peter.
  socket=${MAC_RELEASE_OP_TMUX_SOCKET:-"$socket_dir/clawdbot-op.sock"}
  session=${MAC_RELEASE_OP_TMUX_SESSION:-op-work}
  op_window=
  work_dir=$(mktemp -d /tmp/mac-release-op.XXXXXX)
  script="$work_dir/read-op.sh"
  runner="$work_dir/run-in-tmux.sh"
  env_file="$work_dir/secrets.env"
  log_file="$work_dir/op.log"
  status_file="$work_dir/status"
  local old_exit_trap
  old_exit_trap=$(trap -p EXIT || true)
  # shellcheck disable=SC2329 # invoked via traps while this function is active
  cleanup_1password_env() {
    [[ -z "${work_dir:-}" ]] || rm -rf "$work_dir"
    # Kill only our task window; the op-work session stays for other flows.
    [[ -z "${op_window:-}" ]] || tmux -S "$socket" kill-window -t "$op_window" 2>/dev/null || true
    op_window=
  }
  restore_1password_traps() {
    if [[ -n "$old_exit_trap" ]]; then
      eval "$old_exit_trap"
    else
      trap - EXIT
    fi
    trap - INT TERM
  }
  trap cleanup_1password_env EXIT
  trap 'cleanup_1password_env; exit 130' INT
  trap 'cleanup_1password_env; exit 143' TERM

  cat >"$script" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
set +x

item=${MAC_RELEASE_OP_ITEM:-}
account=${MAC_RELEASE_OP_ACCOUNT:-my.1password.com}
vault=${MAC_RELEASE_OP_VAULT:-}
fields=${MAC_RELEASE_OP_FIELDS:-}
read_primary=${MAC_RELEASE_OP_READ_PRIMARY:-0}
codesign_item=${MAC_RELEASE_CODESIGN_OP_ITEM:-}
codesign_account=${MAC_RELEASE_CODESIGN_OP_ACCOUNT:-$account}
codesign_vault=${MAC_RELEASE_CODESIGN_OP_VAULT-$vault}
codesign_path_field=${MAC_RELEASE_CODESIGN_OP_PATH_FIELD:-keychain_path}
codesign_password_field=${MAC_RELEASE_CODESIGN_OP_PASSWORD_FIELD:-keychain_password}
codesign_passwordless=${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}
read_codesign=${MAC_RELEASE_CODESIGN_OP_READ:-0}
env_file=${MAC_RELEASE_OP_ENV_FILE:?}
log_file=${MAC_RELEASE_OP_LOG_FILE:?}
work_dir=$(mktemp -d /tmp/mac-release-op-json.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
: >"$env_file"

read_item() {
  local target_item=$1 target_account=$2 target_vault=$3 use_service_account=$4 output=$5
  local args=(item get "$target_item" --account "$target_account" --format json)
  if [[ -n "$target_vault" ]]; then
    args+=(--vault "$target_vault")
  fi

  if [[ -n "$target_vault" || "$use_service_account" == "1" ]]; then
    op "${args[@]}" >"$output" 2>>"$log_file"
  else
    env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN op "${args[@]}" >"$output" 2>>"$log_file"
  fi
}

if [[ "$read_primary" == "1" ]]; then
  json_file="$work_dir/primary.json"
  read_item "$item" "$account" "$vault" "${MAC_RELEASE_OP_USE_SERVICE_ACCOUNT:-0}" "$json_file"
  MAC_RELEASE_OP_FIELDS="$fields" node - "$json_file" >>"$env_file" 2>>"$log_file" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const item = JSON.parse(fs.readFileSync(path, "utf8"));
const fields = process.env.MAC_RELEASE_OP_FIELDS.split(/\s+/).filter(Boolean);
const values = new Map((item.fields || []).map((field) => [field.label || field.id, field.value || ""]));
function quote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}
for (const name of fields) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new Error(`invalid env field name: ${name}`);
  }
  const value = values.get(name);
  if (!value) {
    throw new Error(`missing 1Password field: ${name}`);
  }
  process.stdout.write(`export ${name}=${quote(value)}\n`);
  process.stderr.write(`${name}: len=${value.length} escapedNewline=${value.includes("\\n")} realNewline=${value.includes("\n")}\n`);
}
NODE
fi

if [[ "$read_codesign" == "1" ]]; then
  codesign_json_file="$work_dir/codesign.json"
  read_item "$codesign_item" "$codesign_account" "$codesign_vault" "${MAC_RELEASE_CODESIGN_OP_USE_SERVICE_ACCOUNT:-0}" "$codesign_json_file"
  MAC_RELEASE_CODESIGN_OP_PATH_FIELD="$codesign_path_field" \
    MAC_RELEASE_CODESIGN_OP_PASSWORD_FIELD="$codesign_password_field" \
    MAC_RELEASE_CODESIGN_PASSWORDLESS="$codesign_passwordless" \
    node - "$codesign_json_file" >>"$env_file" 2>>"$log_file" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const item = JSON.parse(fs.readFileSync(path, "utf8"));
const values = new Map((item.fields || []).map((field) => [field.label || field.id, field.value || ""]));
const pathField = process.env.MAC_RELEASE_CODESIGN_OP_PATH_FIELD;
const passwordField = process.env.MAC_RELEASE_CODESIGN_OP_PASSWORD_FIELD;
const passwordless = process.env.MAC_RELEASE_CODESIGN_PASSWORDLESS === "1";
const keychainPath = values.get(pathField);
const keychainPassword = values.get(passwordField);
function quote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}
if (!keychainPath) throw new Error(`missing 1Password field: ${pathField}`);
if (!passwordless && !keychainPassword) throw new Error(`missing 1Password field: ${passwordField}`);
process.stdout.write(`export MAC_RELEASE_CODESIGN_KEYCHAIN=${quote(keychainPath)}\n`);
if (!passwordless) {
  process.stdout.write(`MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD=${quote(keychainPassword)}\n`);
}
process.stderr.write(`MAC_RELEASE_CODESIGN_KEYCHAIN: len=${keychainPath.length}\n`);
if (!passwordless) {
  process.stderr.write(`MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD: len=${keychainPassword.length}\n`);
}
NODE
fi

chmod 600 "$env_file"
echo "1Password fields exported: $(wc -l <"$env_file" | tr -d ' ')"
SCRIPT
  chmod 700 "$script"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export PATH=%q\n' "$PATH"
    printf 'export MAC_RELEASE_OP_ITEM=%q\n' "${MAC_RELEASE_OP_ITEM:-}"
    printf 'export MAC_RELEASE_OP_ACCOUNT=%q\n' "$account"
    printf 'export MAC_RELEASE_OP_VAULT=%q\n' "$vault"
    printf 'export MAC_RELEASE_OP_FIELDS=%q\n' "${MAC_RELEASE_OP_FIELDS:-}"
    printf 'export MAC_RELEASE_OP_USE_SERVICE_ACCOUNT=%q\n' "${MAC_RELEASE_OP_USE_SERVICE_ACCOUNT:-0}"
    printf 'export MAC_RELEASE_OP_READ_PRIMARY=%q\n' "$primary_missing"
    printf 'export MAC_RELEASE_CODESIGN_OP_ITEM=%q\n' "${MAC_RELEASE_CODESIGN_OP_ITEM:-}"
    printf 'export MAC_RELEASE_CODESIGN_OP_ACCOUNT=%q\n' "${MAC_RELEASE_CODESIGN_OP_ACCOUNT:-$account}"
    printf 'export MAC_RELEASE_CODESIGN_OP_VAULT=%q\n' "${MAC_RELEASE_CODESIGN_OP_VAULT-$vault}"
    printf 'export MAC_RELEASE_CODESIGN_OP_PATH_FIELD=%q\n' "${MAC_RELEASE_CODESIGN_OP_PATH_FIELD:-keychain_path}"
    printf 'export MAC_RELEASE_CODESIGN_OP_PASSWORD_FIELD=%q\n' "${MAC_RELEASE_CODESIGN_OP_PASSWORD_FIELD:-keychain_password}"
    printf 'export MAC_RELEASE_CODESIGN_PASSWORDLESS=%q\n' "$codesign_passwordless"
    printf 'export MAC_RELEASE_CODESIGN_OP_USE_SERVICE_ACCOUNT=%q\n' "${MAC_RELEASE_CODESIGN_OP_USE_SERVICE_ACCOUNT-${MAC_RELEASE_OP_USE_SERVICE_ACCOUNT:-0}}"
    printf 'export MAC_RELEASE_CODESIGN_OP_READ=%q\n' "$codesign_missing"
    printf 'export MAC_RELEASE_OP_ENV_FILE=%q\n' "$env_file"
    printf 'export MAC_RELEASE_OP_LOG_FILE=%q\n' "$log_file"
    printf 'bash %q\n' "$script"
  } >"$runner"
  chmod 700 "$runner"

  tmux -S "$socket" has-session -t "$session" 2>/dev/null ||
    tmux -S "$socket" new-session -d -s "$session" -n shell
  op_window=$(tmux -S "$socket" new-window -d -t "$session" -n mac-release -P -F '#{window_id}')

  : >"$log_file"
  tmux -S "$socket" send-keys -t "$op_window" -- \
    "bash $(mac_release_tmux_quote "$runner"); printf '%s\n' \$? > $(mac_release_tmux_quote "$status_file")" C-m

  local deadline=$((SECONDS + ${MAC_RELEASE_OP_WAIT_SECONDS:-300}))
  until [[ -f "$status_file" ]]; do
    [[ "$SECONDS" -lt "$deadline" ]] || {
      sed -n '1,80p' "$log_file" >&2 || true
      cleanup_1password_env
      mac_release_die "Timed out waiting for 1Password fields in op tmux session $session"
    }
    sleep 1
  done

  local rc
  rc=$(cat "$status_file")
  if [[ "$rc" != "0" ]]; then
    sed -n '1,120p' "$log_file" >&2 || true
    cleanup_1password_env
    mac_release_die "1Password field export failed in op tmux session $session"
  fi

  # shellcheck source=/dev/null
  source "$env_file"
  if [[ "$mode" == "all" ]]; then
    for release_op_field in ${MAC_RELEASE_OP_FIELDS:-}; do
      export "${release_op_field?}"
      [[ -n "${!release_op_field:-}" ]] || mac_release_die "1Password field did not populate: $release_op_field"
    done
  fi
  if [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    export -n MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  fi
  if [[ -n "${MAC_RELEASE_CODESIGN_OP_ITEM:-}" ]]; then
    export MAC_RELEASE_CODESIGN_KEYCHAIN
    [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" ]] || mac_release_die "1Password did not populate MAC_RELEASE_CODESIGN_KEYCHAIN"
    if [[ "$codesign_passwordless" != "1" ]]; then
      [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]] || mac_release_die "1Password did not populate MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD"
    fi
  fi
  sed -n '1,80p' "$log_file" >&2 || true
  cleanup_1password_env
  restore_1password_traps
}

mac_release_version_from_zip() {
  local zip_name=${1##*/} zip_base
  zip_base=${zip_name%.zip}
  zip_base=${zip_base%.app}
  if [[ "$zip_base" =~ ([0-9]+([.][0-9]+){1,2}([-.][0-9A-Za-z.]+)?)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$MARKETING_VERSION"
  fi
}

mac_release_build_number() {
  local version=${1:?"version required"} core prerelease major minor patch suffix prerelease_label prerelease_number
  core=${version%%-*}
  prerelease=
  if [[ "$version" == *-* ]]; then
    prerelease=${version#*-}
  fi
  IFS=. read -r major minor patch <<<"$core"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] ||
    mac_release_die "Version must be numeric semver: $version"
  ((10#$minor <= 99 && 10#$patch <= 99)) ||
    mac_release_die "Minor and patch versions must be <= 99 for generated build numbers: $version"

  suffix=99
  if [[ -n "$prerelease" ]]; then
    prerelease_label=${prerelease%%.*}
    prerelease_label=${prerelease_label%%-*}
    prerelease_label=${prerelease_label%%[0-9]*}
    prerelease_label=${prerelease_label,,}
    if [[ "$prerelease" =~ ([0-9]+)$ ]]; then
      prerelease_number=${BASH_REMATCH[1]}
    else
      prerelease_number=1
    fi
    ((10#$prerelease_number >= 1 && 10#$prerelease_number <= 29)) ||
      mac_release_die "Prerelease number must be 1..29 for generated build numbers: $version"
    case "$prerelease_label" in
      alpha|a) suffix=$((10#$prerelease_number)) ;;
      beta|b) suffix=$((30 + 10#$prerelease_number)) ;;
      rc) suffix=$((60 + 10#$prerelease_number)) ;;
      *) mac_release_die "Prerelease label must be alpha, beta, or rc for generated build numbers: $version" ;;
    esac
  fi

  printf '%d\n' $((((10#$major * 100 + 10#$minor) * 100 + 10#$patch) * 100 + 10#$suffix))
}

mac_release_load() {
  set +vx
  if [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    export -n MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  fi
  ROOT=${ROOT:-$(mac_release_root)}
  cd "$ROOT" || mac_release_die "Could not cd to release root: $ROOT"
  MAC_RELEASE_MANIFEST=${MAC_RELEASE_MANIFEST:-"$ROOT/.mac-release.env"}
  [[ -f "$MAC_RELEASE_MANIFEST" ]] || mac_release_die "Missing .mac-release.env at $MAC_RELEASE_MANIFEST"

  # shellcheck source=/dev/null
  source "$MAC_RELEASE_MANIFEST"

  if [[ -n "${MAC_RELEASE_SOURCE_FILES:-}" ]]; then
    local release_source_file
    for release_source_file in $MAC_RELEASE_SOURCE_FILES; do
      release_source_file=$(mac_release_expand "$release_source_file")
      [[ -f "$release_source_file" ]] || mac_release_die "Missing release source file: $release_source_file"
      # shellcheck source=/dev/null
      source "$release_source_file"
    done
  fi

  MAC_RELEASE_VERSION_FILE=${MAC_RELEASE_VERSION_FILE:-version.env}
  if [[ "$MAC_RELEASE_VERSION_FILE" != "/dev/null" ]]; then
    [[ -f "$MAC_RELEASE_VERSION_FILE" ]] || mac_release_die "Missing version file: $MAC_RELEASE_VERSION_FILE"
    # shellcheck source=/dev/null
    source "$MAC_RELEASE_VERSION_FILE"
  fi

  MAC_RELEASE_SPARKLE_CHANNEL=${MAC_RELEASE_SPARKLE_CHANNEL:-${SPARKLE_CHANNEL:-}}
  MAC_RELEASE_SPARKLE_ACCOUNT=${MAC_RELEASE_SPARKLE_ACCOUNT:-${SPARKLE_ACCOUNT:-}}

  : "${MARKETING_VERSION:?MARKETING_VERSION missing}"
  BUILD_NUMBER=${BUILD_NUMBER:-$(mac_release_build_number "$MARKETING_VERSION")}
  : "${BUILD_NUMBER:?BUILD_NUMBER missing}"
  : "${MAC_RELEASE_APP_NAME:?MAC_RELEASE_APP_NAME missing}"
  : "${MAC_RELEASE_REPO:?MAC_RELEASE_REPO missing}"
  : "${MAC_RELEASE_BUNDLE_ID:?MAC_RELEASE_BUNDLE_ID missing}"
  : "${MAC_RELEASE_APPCAST:?MAC_RELEASE_APPCAST missing}"
  : "${MAC_RELEASE_FEED_URL:?MAC_RELEASE_FEED_URL missing}"
  : "${MAC_RELEASE_DOWNLOAD_URL_PREFIX:?MAC_RELEASE_DOWNLOAD_URL_PREFIX missing}"
  : "${MAC_RELEASE_APP_ZIP:?MAC_RELEASE_APP_ZIP missing}"
  : "${MAC_RELEASE_PACKAGE_CMD:?MAC_RELEASE_PACKAGE_CMD missing}"

  APP_NAME="$MAC_RELEASE_APP_NAME"
  APPCAST=$(mac_release_expand "$MAC_RELEASE_APPCAST")
  APP_ZIP=$(mac_release_expand "$MAC_RELEASE_APP_ZIP")
  DSYM_ZIP=${MAC_RELEASE_DSYM_ZIP:+$(mac_release_expand "$MAC_RELEASE_DSYM_ZIP")}
  FEED_URL=$(mac_release_expand "$MAC_RELEASE_FEED_URL")
  TAG=${MAC_RELEASE_TAG:-"v${MARKETING_VERSION}"}
  ARTIFACT_PREFIX=${MAC_RELEASE_ARTIFACT_PREFIX:-"${APP_NAME}-"}

  local release_var
  for release_var in ${!MAC_RELEASE_@}; do
    export "${release_var?}"
  done
  if [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    export -n MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  fi
  export ROOT MARKETING_VERSION BUILD_NUMBER APP_NAME APPCAST APP_ZIP DSYM_ZIP FEED_URL TAG ARTIFACT_PREFIX
}

require_clean_worktree() {
  require_bin git
  if [[ -n $(git status --porcelain) ]]; then
    mac_release_die "Working tree is not clean; commit or stash first."
  fi
}

clean_key() {
  local keyfile=${1:?"key file required"}
  [[ -f "$keyfile" ]] || mac_release_die "Sparkle key file not found: $keyfile"
  local lines
  lines=$(grep -v '^[[:space:]]*#' "$keyfile" | sed '/^[[:space:]]*$/d')
  if [[ $(printf "%s\n" "$lines" | wc -l) -ne 1 ]]; then
    mac_release_die "Sparkle key must be a single base64 line (no comments/blank lines)."
  fi
  local tmp
  tmp=$(mktemp)
  printf "%s\n" "$lines" >"$tmp"
  echo "$tmp"
}

probe_sparkle_key() {
  local keyfile=${1:-}
  require_bin sign_update
  local tmp account_args=()
  tmp=$(mktemp /tmp/sparkle-key-probe.XXXX)
  echo test >"$tmp"
  if [[ -n "$keyfile" ]]; then
    sign_update --ed-key-file "$keyfile" -p "$tmp" >/dev/null
  else
    mac_release_sparkle_account_args account_args
    # ${arr[@]+...} keeps empty arrays safe under set -u on macOS bash 3.2
    sign_update ${account_args[@]+"${account_args[@]}"} -p "$tmp" >/dev/null
  fi
  rm -f "$tmp"
}

mac_release_public_key_from_file() {
  local key_file=${1:?"key file required"}
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mac-release-clang-module-cache}" \
    SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mac-release-swift-module-cache}" \
    swift - "$key_file" <<'SWIFT'
import CryptoKit
import Foundation

let path = CommandLine.arguments[1]
let raw = try String(contentsOfFile: path, encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)
guard let secret = Data(base64Encoded: raw) else {
  fputs("Sparkle key file is not base64.\n", stderr)
  exit(1)
}
if secret.count == 32 {
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
  print(key.publicKey.rawRepresentation.base64EncodedString())
} else if secret.count == 96 {
  print(secret.suffix(32).base64EncodedString())
} else {
  fputs("Sparkle key file has unsupported decoded length \(secret.count); expected 32 or 96 bytes.\n", stderr)
  exit(1)
}
SWIFT
}

mac_release_public_key_for_source() {
  local source=${1:-keychain}
  require_bin generate_keys
  if [[ "$source" == "keychain" ]]; then
    local account_args=()
    mac_release_sparkle_account_args account_args
    if [[ "${#account_args[@]}" -gt 0 ]]; then
      generate_keys "${account_args[@]}" -p
    else
      generate_keys -p
    fi
  else
    mac_release_public_key_from_file "$source"
  fi
}

mac_release_expected_public_key() {
  mac_release_load
  if [[ -n "${MAC_RELEASE_SUPUBLIC_ED_KEY:-}" ]]; then
    printf '%s\n' "$MAC_RELEASE_SUPUBLIC_ED_KEY"
    return
  fi
  [[ -n "${MAC_RELEASE_INFO_PLIST:-}" ]] || mac_release_die "Set MAC_RELEASE_INFO_PLIST or MAC_RELEASE_SUPUBLIC_ED_KEY"
  local plist
  plist=$(mac_release_expand "$MAC_RELEASE_INFO_PLIST")
  [[ -f "$plist" ]] || mac_release_die "Info.plist not found: $plist"
  /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist"
}

mac_release_key_source_label() {
  local source=${1:-keychain}
  if [[ "$source" == "keychain" ]]; then
    printf 'Keychain service https://sparkle-project.org account %s' "${MAC_RELEASE_SPARKLE_ACCOUNT:-${SPARKLE_ACCOUNT:-ed25519}}"
  else
    printf '%s' "$source"
  fi
}

mac_release_default_key_source() {
  if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY_FILE"
    return
  fi
  if [[ -n "${MAC_RELEASE_SIGNING_KEY_FILE:-}" ]]; then
    local manifest_key_source
    manifest_key_source=$(mac_release_expand "$MAC_RELEASE_SIGNING_KEY_FILE")
    if [[ -f "$manifest_key_source" ]]; then
      printf '%s\n' "$manifest_key_source"
      return
    fi
  fi
  printf 'keychain\n'
}

mac_release_sparkle_key_status() {
  mac_release_load
  local source=${1:-$(mac_release_default_key_source)}
  local label_source=$source
  local expected actual cleaned_source
  # shellcheck disable=SC2329 # invoked via RETURN trap
  cleanup_key_status() {
    [[ -z "${cleaned_source:-}" ]] || rm -f "$cleaned_source"
  }
  if [[ "$source" != "keychain" ]]; then
    source=$(mac_release_expand "$source")
    label_source=$source
    source=$(clean_key "$source")
    cleaned_source=$source
    trap cleanup_key_status RETURN
  fi
  expected=$(mac_release_expected_public_key)
  actual=$(mac_release_public_key_for_source "$source")
  printf 'app: %s\n' "$APP_NAME"
  printf 'embedded SUPublicEDKey: %s\n' "$expected"
  printf 'signing source: %s\n' "$(mac_release_key_source_label "$label_source")"
  printf 'signing public key: %s\n' "$actual"
  cleanup_key_status
  trap - RETURN
  if [[ "$actual" == "$expected" ]]; then
    printf 'status: match\n'
  else
    printf 'status: mismatch\n' >&2
    return 1
  fi
}

mac_release_key_args_and_validate() {
  local out_var=${1:?"out var"}
  local key_file_var=${2:?"key file var"}
  local key_source source cleaned_key_file actual expected
  key_source=${SPARKLE_PRIVATE_KEY_FILE:-}
  if [[ -z "$key_source" && -n "${MAC_RELEASE_SIGNING_KEY_FILE:-}" ]]; then
    local manifest_key_source
    manifest_key_source=$(mac_release_expand "$MAC_RELEASE_SIGNING_KEY_FILE")
    [[ -f "$manifest_key_source" ]] && key_source=$manifest_key_source
  fi
  if [[ -n "$key_source" ]]; then
    key_source=$(mac_release_expand "$key_source")
    cleaned_key_file=$(clean_key "$key_source")
    source="$cleaned_key_file"
    eval "$key_file_var=\"\$cleaned_key_file\""
    eval "$out_var=(--ed-key-file \"\$cleaned_key_file\")"
  else
    source=keychain
    eval "$key_file_var=\"\""
    mac_release_sparkle_account_args "$out_var"
  fi
  expected=$(mac_release_expected_public_key)
  actual=$(mac_release_public_key_for_source "$source")
  [[ "$actual" == "$expected" ]] || mac_release_die "Sparkle signing key does not match ${APP_NAME} SUPublicEDKey. Run mac-release sparkle-key-status."
  if [[ "$source" == keychain ]]; then
    probe_sparkle_key ""
  else
    probe_sparkle_key "$source"
  fi
}

clear_sparkle_caches() {
  rm -rf "$HOME/Library/Caches/${1}" "$HOME/Library/Caches/org.sparkle-project.Sparkle" || true
}

clean_macos_metadata() {
  local path=${1:?"path required"}
  xattr -cr "$path" 2>/dev/null || true
  find "$path" -name '._*' -delete 2>/dev/null || true
}

safe_zip() {
  local source=${1:?"source bundle/app required"} dest=${2:?"destination zip required"}
  clean_macos_metadata "$source"
  /usr/bin/ditto --norsrc -c -k --keepParent "$source" "$dest"
}

appcast_head_version_build() {
  local appcast=${1:-appcast.xml}
  require_bin python3
  python3 - "$appcast" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
channel = root.find("channel")
item = channel.find("item") if channel is not None else None
if item is None:
    raise SystemExit(1)
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
short_version = item.findtext("sparkle:shortVersionString", default="", namespaces=ns)
build = item.findtext("sparkle:version", default="", namespaces=ns)
enc = item.find("enclosure")
if enc is not None:
    sparkle_ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    short_version = short_version or enc.get(f"{sparkle_ns}shortVersionString", "")
    build = build or enc.get(f"{sparkle_ns}version", "")
print(short_version)
print(build)
PY
}

ensure_appcast_monotonic() {
  local appcast=${1:-appcast.xml} version=${2:?"version required"} build=${3:?"build required"}
  local current cur_ver cur_build
  current=$(appcast_head_version_build "$appcast" || true)
  cur_ver=$(printf "%s\n" "$current" | sed -n '1p')
  cur_build=$(printf "%s\n" "$current" | sed -n '2p')
  if [[ -n "$cur_ver" && "$cur_ver" == "$version" ]]; then
    mac_release_die "appcast already has version $version; bump version first."
  fi
  if [[ -n "$cur_build" && "$build" -le "$cur_build" ]]; then
    mac_release_die "Build number $build must be greater than latest appcast build $cur_build."
  fi
}

ensure_changelog_finalized() {
  local version=${1:?"version required"}
  require_bin python3
  python3 - "$version" <<'PY'
import sys, pathlib, re
version = sys.argv[1]
text = pathlib.Path("CHANGELOG.md").read_text()
first = re.search(r"^##\s+(.+)$", text, re.M)
if not first:
    raise SystemExit("No changelog sections found")
header = first.group(1)
if "Unreleased" in header:
    raise SystemExit("Top changelog section still marked Unreleased")
version_token = rf"(?:{re.escape(version)}|\[{re.escape(version)}\])"
version_header = re.compile(rf"^{version_token}(?:\s+.*)?$")
if not version_header.fullmatch(header):
    raise SystemExit(f"Top changelog section '{header}' does not match version {version}")
if not re.search(rf"^##\s+{version_token}(?:\s|$)", text, re.M):
    raise SystemExit(f"No section found for version {version}")
PY
}

extract_notes_from_changelog() {
  local version=${1:?"version required"}
  local dest=${2:?"dest path required"}
  require_bin python3
  python3 - "$version" "$dest" <<'PY'
import sys, pathlib, re
version, dest = sys.argv[1], pathlib.Path(sys.argv[2])
text = pathlib.Path("CHANGELOG.md").read_text()
pattern = re.compile(rf"^##\s+(?:\[)?{re.escape(version)}(?:\])?(?:\s+.*)?$", re.M)
m = pattern.search(text)
if not m:
    raise SystemExit("section not found")
start = m.end()
next_header = text.find("\n## ", start)
chunk = text[start: next_header if next_header != -1 else len(text)]
lines = [ln for ln in chunk.strip().splitlines() if ln.strip()]
dest.write_text("\n".join(lines) + "\n")
PY
}

mac_release_changelog_html() {
  local version=${1:?"version required"}
  local changelog=${2:-CHANGELOG.md}
  mac_release_load
  require_bin python3
  python3 - "$version" "$changelog" "$APP_NAME" "$MAC_RELEASE_REPO" <<'PY'
import html, pathlib, re, sys
version, changelog, app, repo = sys.argv[1:5]
text = pathlib.Path(changelog).read_text()
pattern = re.compile(rf"^##\s+(?:\[)?{re.escape(version)}(?:\])?(?:\s+.*)?$", re.M)
m = pattern.search(text)
if not m:
    raise SystemExit(f"changelog section not found for {version}")
section = text[m.end(): text.find("\n## ", m.end()) if text.find("\n## ", m.end()) != -1 else len(text)].strip()
print(f"<h2>{html.escape(app)} {html.escape(version)}</h2>")
in_list = False
para = []
def format_inline(value):
    out = []
    pos = 0
    token_re = re.compile(r"`([^`]+)`|\*\*([^*]+)\*\*|\[([^\]]+)\]\((https?://[^)\s]+)\)")
    for match in token_re.finditer(value):
        out.append(html.escape(value[pos:match.start()]))
        if match.group(1) is not None:
            out.append(f"<code>{html.escape(match.group(1))}</code>")
        elif match.group(2) is not None:
            out.append(f"<strong>{html.escape(match.group(2))}</strong>")
        else:
            label = html.escape(match.group(3))
            href = html.escape(match.group(4), quote=True)
            out.append(f'<a href="{href}">{label}</a>')
        pos = match.end()
    out.append(html.escape(value[pos:]))
    return "".join(out)
def flush_para():
    global para
    if para:
        print("<p>{}</p>".format(format_inline(" ".join(para))))
        para = []
def close_list():
    global in_list
    if in_list:
        print("</ul>")
        in_list = False
for raw in section.splitlines():
    line = raw.rstrip()
    if not line.strip():
        flush_para(); close_list(); continue
    if line.startswith("### "):
        flush_para(); close_list(); print(f"<h3>{html.escape(line[4:].strip())}</h3>"); continue
    bullet = re.match(r"^[-*]\s+(.*)$", line.strip())
    if bullet:
        flush_para()
        if not in_list:
            print("<ul>"); in_list = True
        print(f"<li>{format_inline(bullet.group(1))}</li>")
    else:
        close_list()
        para.append(line.strip())
flush_para(); close_list()
print(f'<p><a href="https://github.com/{html.escape(repo)}/blob/main/CHANGELOG.md">View full changelog</a></p>')
PY
}

mac_release_appcast_meta() {
  local appcast=${1:?"appcast"} version=${2:?"version"} out=${3:?"out"}
  require_bin python3
  python3 - "$appcast" "$version" >"$out" <<'PY'
import sys, xml.etree.ElementTree as ET
appcast, version = sys.argv[1], sys.argv[2]
root = ET.parse(appcast).getroot()
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in root.findall("./channel/item"):
    if item.findtext("sparkle:shortVersionString", default="", namespaces=ns) == version:
        enc = item.find("enclosure")
        if enc is None:
            raise SystemExit(f"No enclosure for version {version}")
        url = enc.get("url")
        sig = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        length = enc.get("length")
        if not all([url, sig, length]):
            raise SystemExit(f"Missing url/signature/length for version {version}")
        print(url); print(sig); print(length)
        raise SystemExit(0)
    enc = item.find("enclosure")
    if enc is not None and enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString") == version:
        url = enc.get("url")
        sig = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        length = enc.get("length")
        if not all([url, sig, length]):
            raise SystemExit(f"Missing url/signature/length for version {version}")
        print(url); print(sig); print(length)
        raise SystemExit(0)
raise SystemExit(f"No appcast entry for version {version}")
PY
}

verify_enclosure() {
  local url=$1 sig=$2 key_file=$3 expected_len=$4
  require_bin curl sign_update
  local tmp account_args=()
  tmp=$(mktemp /tmp/sparkle-enclosure.XXXX)
  trap 'rm -f "${tmp:-}"' RETURN
  curl -L -o "$tmp" "$url"
  local len
  len=$(stat -f%z "$tmp")
  [[ "$len" == "$expected_len" ]] || mac_release_die "Length mismatch for $url (expected $expected_len, got $len)"
  if [[ -n "$key_file" ]]; then
    sign_update --verify "$tmp" "$sig" --ed-key-file "$key_file"
  else
    mac_release_sparkle_account_args account_args
    # ${arr[@]+...} keeps empty arrays safe under set -u on macOS bash 3.2
    sign_update ${account_args[@]+"${account_args[@]}"} --verify "$tmp" "$sig"
  fi
}

verify_distribution_policy() {
  local app=${1:?"app bundle required"}
  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$app"
  else
    require_bin spctl
    spctl --assess --type execute --verbose "$app"
  fi
}

verify_codesign_from_enclosure() {
  local url=${1:?"enclosure URL required"}
  require_bin curl ditto codesign
  local tmp_dir tmp_zip app
  tmp_dir=$(mktemp -d /tmp/sparkle-verify.XXXX)
  trap 'rm -rf "${tmp_dir:-}"' RETURN
  tmp_zip="$tmp_dir/enclosure.zip"
  curl -L -o "$tmp_zip" "$url"
  /usr/bin/ditto -x -k --norsrc "$tmp_zip" "$tmp_dir"
  app=$(find "$tmp_dir" -maxdepth 2 -name "${APP_NAME}.app" -not -path "*/__MACOSX/*" | head -n 1)
  [[ -n "$app" ]] || mac_release_die "No ${APP_NAME}.app found in enclosure $url"
  codesign --verify --deep --strict --verbose=2 "$app"
  verify_distribution_policy "$app"
  if command -v stapler >/dev/null 2>&1; then
    stapler validate "$app"
  fi
  echo "Codesign/system-policy/stapler verification OK for $(basename "$app")"
}

verify_appcast_entry() {
  local appcast=${1:?"appcast path"} version=${2:?"version"} key_file=${3:-}
  local tmp_meta url sig length
  tmp_meta=$(mktemp)
  trap 'rm -f "${tmp_meta:-}"' RETURN
  mac_release_appcast_meta "$appcast" "$version" "$tmp_meta"
  url=$(sed -n '1p' "$tmp_meta")
  sig=$(sed -n '2p' "$tmp_meta")
  length=$(sed -n '3p' "$tmp_meta")
  verify_enclosure "$url" "$sig" "$key_file" "$length"
  echo "Appcast entry $version verified (signature & length)."
  verify_codesign_from_enclosure "$url"
}

check_assets() {
  local tag=${1:?"tag"} prefix=${2:-} repo
  ROOT=${ROOT:-$(mac_release_root)}
  if [[ -z "$prefix" ]]; then
    mac_release_load
    prefix=$ARTIFACT_PREFIX
  elif [[ -f "${MAC_RELEASE_MANIFEST:-$ROOT/.mac-release.env}" ]]; then
    mac_release_load
  fi
  require_bin gh
  repo=${MAC_RELEASE_REPO:-}
  if [[ -z "$repo" ]]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  fi
  local assets zip="" dsym="" expected_zip="" expected_dsym="" old_marketing_version asset_version
  if gh --live release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' >/dev/null 2>&1; then
    assets=$(gh --live release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')
  else
    assets=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')
  fi
  if [[ -n "${MAC_RELEASE_APP_ZIP:-}" ]]; then
    asset_version=${tag#v}
    old_marketing_version=${MARKETING_VERSION:-}
    MARKETING_VERSION="$asset_version"
    expected_zip=$(basename "$(mac_release_expand "$MAC_RELEASE_APP_ZIP")")
    expected_dsym=${MAC_RELEASE_DSYM_ZIP:+$(basename "$(mac_release_expand "$MAC_RELEASE_DSYM_ZIP")")}
    MARKETING_VERSION="$old_marketing_version"
    zip=$(printf "%s\n" "$assets" | grep -Fx "$expected_zip" || true)
    if [[ -n "$expected_dsym" ]]; then
      dsym=$(printf "%s\n" "$assets" | grep -Fx "$expected_dsym" || true)
    fi
  else
    zip=$(printf "%s\n" "$assets" | grep -E "^${prefix}[0-9]+(\\.[0-9]+)*(-[0-9A-Za-z.]+)?\\.zip$" || true)
    dsym=$(printf "%s\n" "$assets" | grep -E "^${prefix}[0-9]+(\\.[0-9]+)*(-[0-9A-Za-z.]+)?\\.dSYM\\.zip$" || true)
  fi
  [[ -z "$zip" ]] && mac_release_die "app zip missing on release $tag"
  if [[ -n "${MAC_RELEASE_DSYM_ZIP:-}" || "${MAC_RELEASE_REQUIRE_DSYM:-1}" == "1" ]]; then
    [[ -z "$dsym" ]] && mac_release_die "dSYM zip missing on release $tag"
    echo "Release $tag has zip ($zip) and dSYM ($dsym)."
  else
    echo "Release $tag has zip ($zip)."
  fi
  if [[ "${MAC_RELEASE_SKIP_EXTRA_ASSET_CHECK:-0}" != "1" && -n "${MAC_RELEASE_EXTRA_ASSET_PATTERNS:-}" ]]; then
    local pattern missing=0 asset_version old_marketing_version
    asset_version=${tag#v}
    old_marketing_version=${MARKETING_VERSION:-}
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      MARKETING_VERSION="$asset_version"
      pattern=$(mac_release_expand "$pattern")
      MARKETING_VERSION="$old_marketing_version"
      if ! printf "%s\n" "$assets" | grep -Eq "$pattern"; then
        echo "ERROR: extra asset missing on release $tag: $pattern" >&2
        missing=1
      fi
    done <<< "$MAC_RELEASE_EXTRA_ASSET_PATTERNS"
    [[ "$missing" == "0" ]] || exit 1
  fi
}

wait_for_assets() {
  local tag=${1:?"tag"} prefix=${2:-} wait_seconds=${MAC_RELEASE_EXTRA_ASSET_WAIT_SECONDS:-0}
  local interval=${MAC_RELEASE_EXTRA_ASSET_WAIT_INTERVAL:-30} deadline
  if [[ "$wait_seconds" -le 0 ]]; then
    check_assets "$tag" "$prefix"
    return
  fi
  deadline=$((SECONDS + wait_seconds))
  until ( check_assets "$tag" "$prefix" ); do
    [[ "$SECONDS" -lt "$deadline" ]] || mac_release_die "release assets not ready before timeout for $tag"
    echo "Waiting for release assets on $tag..."
    sleep "$interval"
  done
}

mac_release_make_appcast() {
  mac_release_load
  local zip=${1:?"Usage: mac-release make-appcast <zip> [feed-url]"}
  local feed_url=${2:-$FEED_URL}
  [[ -f "$zip" ]] || mac_release_die "Zip not found: $zip"
  require_bin generate_appcast
  local zip_dir zip_name zip_base version notes_html work_dir key_file download_url_prefix old_marketing_version
  zip_dir=$(cd "$(dirname "$zip")" && pwd)
  zip_name=$(basename "$zip")
  zip_base="${zip_name%.zip}"
  version=${SPARKLE_RELEASE_VERSION:-$(mac_release_version_from_zip "$zip_name")}
  notes_html="$zip_dir/$zip_base.html"
  mac_release_changelog_html "$version" "$ROOT/CHANGELOG.md" > "$notes_html"
  work_dir=$(mktemp -d /tmp/mac-release-appcast.XXXXXX)
  KEY_ARGS=()
  key_file=""
  # shellcheck disable=SC2329 # invoked via EXIT trap
  cleanup() {
    [[ -n "${key_file:-}" ]] && rm -f "$key_file"
    [[ -z "${work_dir:-}" ]] || rm -rf "$work_dir"
    [[ "${KEEP_SPARKLE_NOTES:-0}" == "1" || -z "${notes_html:-}" ]] || rm -f "$notes_html"
  }
  trap cleanup EXIT
  mac_release_key_args_and_validate KEY_ARGS key_file
  cp "$APPCAST" "$work_dir/appcast.xml"
  cp "$zip" "$work_dir/$zip_name"
  cp "$notes_html" "$work_dir/$zip_base.html"
  pushd "$work_dir" >/dev/null || mac_release_die "Could not enter appcast workspace: $work_dir"
  local extra_args=()
  if [[ -n "${MAC_RELEASE_GENERATE_APPCAST_ARGS:-}" ]]; then
    eval "extra_args=(${MAC_RELEASE_GENERATE_APPCAST_ARGS})"
  fi
  old_marketing_version=$MARKETING_VERSION
  MARKETING_VERSION="$version"
  download_url_prefix=$(mac_release_expand "$MAC_RELEASE_DOWNLOAD_URL_PREFIX")
  MARKETING_VERSION=$old_marketing_version
  generate_appcast \
    "${KEY_ARGS[@]}" \
    --download-url-prefix "$download_url_prefix" \
    --embed-release-notes \
    --link "$feed_url" \
    "${extra_args[@]}" \
    "$work_dir"
  popd >/dev/null || mac_release_die "Could not leave appcast workspace: $work_dir"
  if [[ -n "${MAC_RELEASE_SPARKLE_CHANNEL:-}" ]]; then
    python3 - "$work_dir/appcast.xml" "$version" "$MAC_RELEASE_SPARKLE_CHANNEL" <<'PY'
import re, sys
path, version, channel = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().splitlines()
target = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
idx = next((i for i, line in enumerate(lines) if target in line), None)
if idx is None:
    raise SystemExit(f"Could not find {target} in {path}")
for j in range(idx, -1, -1):
    if "<item" in lines[j]:
        lines[j] = re.sub(r'sparkle:channel="[^"]*"', f'sparkle:channel="{channel}"', lines[j]) if "sparkle:channel" in lines[j] else lines[j].replace("<item", f'<item sparkle:channel="{channel}"', 1)
        break
else:
    raise SystemExit(f"Could not find <item> for version {version}")
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
    echo "Tagged ${version} with sparkle:channel=\"${MAC_RELEASE_SPARKLE_CHANNEL}\""
  fi
  cp "$work_dir/appcast.xml" "$APPCAST"
  echo "Appcast generated: $APPCAST"
  trap - EXIT
  cleanup
}

mac_release_verify_appcast() {
  mac_release_load
  local version=${1:-$MARKETING_VERSION}
  [[ -f "$APPCAST" ]] || mac_release_die "appcast not found: $APPCAST"
  KEY_ARGS=()
  local key_file=""
  trap '[[ -n "${key_file:-}" ]] && rm -f "$key_file"' EXIT
  mac_release_key_args_and_validate KEY_ARGS key_file
  verify_appcast_entry "$APPCAST" "$version" "$key_file"
}

mac_release_status() {
  mac_release_load
  local head
  head=$(appcast_head_version_build "$APPCAST" || true)
  printf 'app: %s\n' "$APP_NAME"
  printf 'repo: %s\n' "$MAC_RELEASE_REPO"
  printf 'version: %s\n' "$MARKETING_VERSION"
  printf 'build: %s\n' "$BUILD_NUMBER"
  printf 'app zip: %s\n' "$APP_ZIP"
  [[ -n "$DSYM_ZIP" ]] && printf 'dSYM zip: %s\n' "$DSYM_ZIP"
  printf 'appcast head version: %s\n' "$(printf "%s\n" "$head" | sed -n '1p')"
  printf 'appcast head build: %s\n' "$(printf "%s\n" "$head" | sed -n '2p')"
  mac_release_sparkle_key_status "${1:-$(mac_release_default_key_source)}" || true
}

mac_release_run_cmd() {
  local label=$1 cmd=$2
  [[ -z "$cmd" ]] && return 0
  echo "==> $label"
  if [[ "${MAC_RELEASE_RUN_LOGIN_SHELL:-0}" == "1" ]]; then
    bash -lc "$cmd"
  else
    env -u BASH_ENV bash -c "$cmd"
  fi
}

mac_release_run_with_timeout() {
  local seconds=${1:?"timeout required"}
  shift
  python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
try:
    sys.exit(
        subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        ).returncode
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}

MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN=
MAC_RELEASE_CODESIGN_ORIGINAL_PATH=
MAC_RELEASE_CODESIGN_SHIM_DIR=
MAC_RELEASE_ORIGINAL_KEYCHAINS=()
MAC_RELEASE_CODESIGN_SEARCH_PREPARED=0
MAC_RELEASE_CODESIGN_SETTINGS_PREPARED=0
MAC_RELEASE_CODESIGN_ORIGINAL_LOCK_ON_SLEEP=0
MAC_RELEASE_CODESIGN_ORIGINAL_TIMEOUT=
MAC_RELEASE_CODESIGN_LOCK_FILE=
MAC_RELEASE_CODESIGN_LOCK_HELD=0
MAC_RELEASE_CODESIGN_PASSWORDLESS_ACTIVE=0

mac_release_security_with_password() {
  set +vx
  local password=${1-}
  shift
  expect -f /dev/stdin "$@" 3< <(printf '%s' "$password") <<'EXPECT'
set timeout 30
log_user 0
set password_channel [open "/dev/fd/3" r]
fconfigure $password_channel -translation binary -encoding binary
set password [read $password_channel]
close $password_channel
set password_sent 0

spawn -noecho {*}$argv
expect {
  -nocase -re {password[^\r\n]*:} {
    if {$password_sent} {
      close
      wait
      exit 1
    }
    send -- "$password\r"
    set password_sent 1
    exp_continue
  }
  eof {}
  timeout {
    close
    wait
    exit 124
  }
}
set wait_result [wait]
exit [lindex $wait_result 3]
EXPECT
}

mac_release_decode_keychain_list() {
  local serialized=${1:-}
  MAC_RELEASE_SERIALIZED_KEYCHAINS=$serialized node <<'NODE'
const input = process.env.MAC_RELEASE_SERIALIZED_KEYCHAINS || "";
const lines = input.split(/\r?\n/).filter((line) => line.trim().length > 0);

function decode(line) {
  const text = line.trim();
  if (text.length < 2 || text[0] !== '"' || text[text.length - 1] !== '"') {
    throw new Error("unexpected keychain search-list entry");
  }
  const chunks = [];
  for (let index = 1; index < text.length - 1;) {
    const character = text[index];
    if (character !== "\\") {
      const codePoint = text.codePointAt(index);
      chunks.push(Buffer.from(String.fromCodePoint(codePoint), "utf8"));
      index += codePoint > 0xffff ? 2 : 1;
      continue;
    }
    index += 1;
    if (index >= text.length - 1) throw new Error("trailing keychain escape");
    const escape = text[index];
    if (/[0-7]/.test(escape)) {
      let octal = escape;
      index += 1;
      while (index < text.length - 1 && octal.length < 3 && /[0-7]/.test(text[index])) {
        octal += text[index];
        index += 1;
      }
      chunks.push(Buffer.from([Number.parseInt(octal, 8)]));
      continue;
    }
    const escapes = {
      "\\": 0x5c,
      '"': 0x22,
      n: 0x0a,
      r: 0x0d,
      t: 0x09,
      b: 0x08,
      f: 0x0c,
      v: 0x0b,
      a: 0x07,
    };
    if (!(escape in escapes)) throw new Error(`unsupported keychain escape: \\${escape}`);
    chunks.push(Buffer.from([escapes[escape]]));
    index += 1;
  }
  return Buffer.concat(chunks);
}

const decoded = lines.map(decode);
process.stdout.write(Buffer.from(`${decoded.length}\0`));
for (const path of decoded) {
  process.stdout.write(path);
  process.stdout.write(Buffer.from([0]));
}
NODE
}

mac_release_restore_codesign_keychains() {
  local cleanup_failed=0
  local settings_args=()
  if [[ "${MAC_RELEASE_CODESIGN_SEARCH_PREPARED:-0}" == "1" ]]; then
    if security list-keychains -d user -s "${MAC_RELEASE_ORIGINAL_KEYCHAINS[@]}"; then
      MAC_RELEASE_ORIGINAL_KEYCHAINS=()
      MAC_RELEASE_CODESIGN_SEARCH_PREPARED=0
    else
      echo "ERROR: Could not restore user keychain search list" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "${MAC_RELEASE_CODESIGN_ORIGINAL_PATH:-}" ]]; then
    PATH=$MAC_RELEASE_CODESIGN_ORIGINAL_PATH
    export PATH
  fi
  if [[ -n "${MAC_RELEASE_CODESIGN_SHIM_DIR:-}" ]]; then
    rm -rf "$MAC_RELEASE_CODESIGN_SHIM_DIR"
  fi
  if [[ "${MAC_RELEASE_CODESIGN_SETTINGS_PREPARED:-0}" == "1" ]]; then
    [[ "$MAC_RELEASE_CODESIGN_ORIGINAL_LOCK_ON_SLEEP" == "1" ]] && settings_args+=(-l)
    if [[ -n "$MAC_RELEASE_CODESIGN_ORIGINAL_TIMEOUT" ]]; then
      settings_args+=(-u -t "$MAC_RELEASE_CODESIGN_ORIGINAL_TIMEOUT")
    fi
    if security set-keychain-settings "${settings_args[@]}" "$MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN"; then
      MAC_RELEASE_CODESIGN_SETTINGS_PREPARED=0
      MAC_RELEASE_CODESIGN_ORIGINAL_LOCK_ON_SLEEP=0
      MAC_RELEASE_CODESIGN_ORIGINAL_TIMEOUT=
    else
      echo "ERROR: Could not restore Developer ID keychain lock settings" >&2
      return 1
    fi
  fi
  if [[ -n "${MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN:-}" && "${MAC_RELEASE_CODESIGN_PASSWORDLESS_ACTIVE:-0}" == "1" ]]; then
    MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN=
    MAC_RELEASE_CODESIGN_PASSWORDLESS_ACTIVE=0
  elif [[ -n "${MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN:-}" ]]; then
    if security lock-keychain "$MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN" >/dev/null 2>&1; then
      MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN=
    else
      echo "ERROR: Could not relock Developer ID keychain: $MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN" >&2
      cleanup_failed=1
    fi
  fi
  if [[ "$cleanup_failed" == "0" && "${MAC_RELEASE_CODESIGN_LOCK_HELD:-0}" == "1" ]]; then
    rm -f "$MAC_RELEASE_CODESIGN_LOCK_FILE"
    MAC_RELEASE_CODESIGN_LOCK_FILE=
    MAC_RELEASE_CODESIGN_LOCK_HELD=0
  fi
  MAC_RELEASE_CODESIGN_ORIGINAL_PATH=
  MAC_RELEASE_CODESIGN_SHIM_DIR=
  return "$cleanup_failed"
}

mac_release_prepare_codesign_keychain() {
  set +vx
  [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" || -n "${MAC_RELEASE_CODESIGN_IDENTITY:-}" ]] || return 0
  [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" ]] || mac_release_die "Set MAC_RELEASE_CODESIGN_KEYCHAIN with MAC_RELEASE_CODESIGN_IDENTITY"
  [[ -n "${MAC_RELEASE_CODESIGN_IDENTITY:-}" ]] || mac_release_die "Set MAC_RELEASE_CODESIGN_IDENTITY with MAC_RELEASE_CODESIGN_KEYCHAIN"
  [[ "${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}" == "0" || "${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}" == "1" ]] ||
    mac_release_die "MAC_RELEASE_CODESIGN_PASSWORDLESS must be 0 or 1"
  if [[ "${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}" != "1" ]]; then
    [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD:-}" ]] || mac_release_die "Set MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD or MAC_RELEASE_CODESIGN_OP_ITEM"
  fi
  [[ "${MAC_RELEASE_CODESIGN_KEYCHAIN_MANAGED:-0}" == "1" ]] ||
    mac_release_die "Set MAC_RELEASE_CODESIGN_KEYCHAIN_MANAGED=1 for a dedicated automation-owned keychain"
  require_bin security codesign shlock stat expect node python3

  local keychain identity password probe_dir probe_path default_keychain signing_key_count existing_keychain
  local keychain_file_id default_keychain_file_id keychain_settings signature_info keychain_list expected_keychain_count
  local canary_rc developer_id_requirement
  local signing_search=() keychain_records=()
  keychain=$(mac_release_expand_home_path "$MAC_RELEASE_CODESIGN_KEYCHAIN")
  identity=$MAC_RELEASE_CODESIGN_IDENTITY
  if [[ "${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}" == "1" ]]; then
    password=
    unset MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  else
    password=$MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  fi
  [[ -f "$keychain" ]] || mac_release_die "Developer ID keychain not found: $keychain"
  default_keychain=$(security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  keychain_file_id=$(stat -L -f '%d:%i' "$keychain")
  default_keychain_file_id=$(stat -L -f '%d:%i' "$default_keychain")
  [[ "$keychain_file_id" != "$default_keychain_file_id" ]] ||
    mac_release_die "Developer ID automation requires a dedicated keychain, not the default keychain"
  MAC_RELEASE_CODESIGN_LOCK_FILE="/tmp/mac-release-codesign-${UID}.lock"
  if ! shlock -f "$MAC_RELEASE_CODESIGN_LOCK_FILE" -p "$$"; then
    mac_release_die "Another macOS release is using the user keychain search list"
  fi
  MAC_RELEASE_CODESIGN_LOCK_HELD=1
  if ! keychain_list=$(security list-keychains -d user); then
    mac_release_restore_codesign_keychains
    mac_release_die "Could not read user keychain search list"
  fi
  MAC_RELEASE_ORIGINAL_KEYCHAINS=()
  while IFS= read -r -d '' existing_keychain; do
    keychain_records+=("$existing_keychain")
  done < <(mac_release_decode_keychain_list "$keychain_list")
  [[ "${#keychain_records[@]}" -ge 1 && "${keychain_records[0]}" =~ ^[0-9]+$ ]] || {
    mac_release_restore_codesign_keychains
    mac_release_die "Could not decode user keychain search list"
  }
  expected_keychain_count=${keychain_records[0]}
  local actual_keychain_count
  actual_keychain_count=$((${#keychain_records[@]} - 1))
  [[ "$expected_keychain_count" -eq "$actual_keychain_count" ]] || {
    mac_release_restore_codesign_keychains
    mac_release_die "Incomplete user keychain search list"
  }
  MAC_RELEASE_ORIGINAL_KEYCHAINS=("${keychain_records[@]:1}")
  if [[ "${#MAC_RELEASE_ORIGINAL_KEYCHAINS[@]}" -eq 0 ]]; then
    mac_release_restore_codesign_keychains
    mac_release_die "Developer ID automation requires a nonempty user keychain search list"
  fi

  MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN=$keychain
  MAC_RELEASE_CODESIGN_PASSWORDLESS_ACTIVE=${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}
  # security marks -p/-k as insecure. Drive its CLI prompt through an isolated
  # PTY while the password arrives on fd 3, never argv, env, logs, or a GUI.
  if ! mac_release_security_with_password "$password" security unlock-keychain "$keychain"; then
    mac_release_restore_codesign_keychains
    mac_release_die "Could not unlock Developer ID keychain"
  fi
  signing_key_count=$(security find-key -s -t private "$keychain" | grep -c '^keychain:' || true)
  if [[ "$signing_key_count" != "1" ]]; then
    mac_release_restore_codesign_keychains
    mac_release_die "Developer ID automation requires a dedicated keychain with exactly one signing private key"
  fi
  if [[ "${MAC_RELEASE_CODESIGN_PASSWORDLESS:-0}" == "1" ]]; then
    if ! security set-keychain-settings "$keychain"; then
      mac_release_restore_codesign_keychains
      mac_release_die "Could not configure passwordless Developer ID keychain to remain unlocked"
    fi
  else
    if ! keychain_settings=$(security show-keychain-info "$keychain" 2>&1); then
      mac_release_restore_codesign_keychains
      mac_release_die "Could not read Developer ID keychain lock settings"
    fi
    [[ "$keychain_settings" == *lock-on-sleep* ]] && MAC_RELEASE_CODESIGN_ORIGINAL_LOCK_ON_SLEEP=1
    if [[ "$keychain_settings" =~ timeout=([0-9]+)s ]]; then
      MAC_RELEASE_CODESIGN_ORIGINAL_TIMEOUT=${BASH_REMATCH[1]}
    fi
    MAC_RELEASE_CODESIGN_SETTINGS_PREPARED=1
    if ! security set-keychain-settings -ut "${MAC_RELEASE_CODESIGN_KEYCHAIN_TIMEOUT:-21600}" "$keychain"; then
      mac_release_restore_codesign_keychains
      mac_release_die "Could not configure Developer ID keychain timeout"
    fi
  fi
  # This keychain is explicitly automation-owned. Keep its private-key ACL
  # normalized so unattended codesign never falls back to SecurityAgent.
  if ! mac_release_security_with_password "$password" \
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$keychain"; then
    mac_release_restore_codesign_keychains
    mac_release_die "Could not configure Developer ID keychain partition list"
  fi
  unset MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD password

  export MAC_RELEASE_CODESIGN_KEYCHAIN="$keychain"
  export CODESIGN_KEYCHAIN="$keychain"
  signing_search=("$keychain")
  for existing_keychain in "${MAC_RELEASE_ORIGINAL_KEYCHAINS[@]}"; do
    [[ "$existing_keychain" == "$keychain" ]] || signing_search+=("$existing_keychain")
  done
  MAC_RELEASE_CODESIGN_SEARCH_PREPARED=1
  if ! security list-keychains -d user -s "${signing_search[@]}"; then
    mac_release_restore_codesign_keychains
    mac_release_die "Could not configure user keychain search list"
  fi

  probe_dir=$(mktemp -d /tmp/mac-release-codesign.XXXXXX)
  probe_path="$probe_dir/probe"
  cp /usr/bin/true "$probe_path"
  canary_rc=0
  mac_release_run_with_timeout "${MAC_RELEASE_CODESIGN_CANARY_TIMEOUT:-30}" \
    codesign --force --timestamp=none --keychain "$keychain" --sign "$identity" "$probe_path" ||
    canary_rc=$?
  if [[ "$canary_rc" != "0" ]]; then
    rm -rf "$probe_dir"
    mac_release_restore_codesign_keychains
    if [[ "$canary_rc" == "124" ]]; then
      mac_release_die "Developer ID signing canary timed out; aborting before packaging"
    fi
    mac_release_die "Developer ID signing canary failed without opening a release. Check keychain password and partition list."
  fi
  developer_id_requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  if ! codesign --verify --strict -R="$developer_id_requirement" "$probe_path" >/dev/null 2>&1; then
    rm -rf "$probe_dir"
    mac_release_restore_codesign_keychains
    mac_release_die "Developer ID signing canary failed Apple trust validation"
  fi
  signature_info=$(codesign -dvvv "$probe_path" 2>&1)
  if ! printf '%s\n' "$signature_info" | grep -q '^Authority=Developer ID Application:'; then
    rm -rf "$probe_dir"
    mac_release_restore_codesign_keychains
    mac_release_die "Signing canary is not signed by a Developer ID Application identity"
  fi
  rm -rf "$probe_dir"

  MAC_RELEASE_CODESIGN_ORIGINAL_PATH=$PATH
  MAC_RELEASE_CODESIGN_SHIM_DIR=$(mktemp -d /tmp/mac-release-codesign-shim.XXXXXX)
  cat >"$MAC_RELEASE_CODESIGN_SHIM_DIR/codesign" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

signing=0
has_keychain=0
for arg in "$@"; do
  case "$arg" in
    --sign|--sign=*) signing=1 ;;
    --keychain|--keychain=*) has_keychain=1 ;;
    --*) ;;
    -*) [[ "${arg#-}" == *s* ]] && signing=1 ;;
  esac
done

if [[ "$signing" == "1" && "$has_keychain" == "0" ]]; then
  exec /usr/bin/codesign --keychain "${CODESIGN_KEYCHAIN:?}" "$@"
fi
exec /usr/bin/codesign "$@"
SCRIPT
  chmod 700 "$MAC_RELEASE_CODESIGN_SHIM_DIR/codesign"
  PATH="$MAC_RELEASE_CODESIGN_SHIM_DIR:$PATH"
  export PATH
  echo "Developer ID keychain prepared without GUI interaction."
}

mac_release_load_codesign_config() {
  set +vx
  ROOT=${ROOT:-$(mac_release_root)}
  cd "$ROOT" || mac_release_die "Could not cd to release root: $ROOT"
  local manifest=${MAC_RELEASE_MANIFEST:-"$ROOT/.mac-release.env"}
  if [[ -f "$manifest" ]]; then
    # shellcheck source=/dev/null
    source "$manifest"
  elif [[ -n "${MAC_RELEASE_MANIFEST:-}" ]]; then
    mac_release_die "Missing release manifest: $manifest"
  fi

  [[ -n "${MAC_RELEASE_CODESIGN_IDENTITY:-}" ]] ||
    mac_release_die "codesign-run requires MAC_RELEASE_CODESIGN_IDENTITY or a release manifest"
  [[ -n "${MAC_RELEASE_CODESIGN_KEYCHAIN:-}" || -n "${MAC_RELEASE_CODESIGN_OP_ITEM:-}" ]] ||
    mac_release_die "codesign-run requires a managed keychain or MAC_RELEASE_CODESIGN_OP_ITEM"
  export MAC_RELEASE_CODESIGN_IDENTITY
  export MAC_RELEASE_CODESIGN_KEYCHAIN_MANAGED
  export MAC_RELEASE_CODESIGN_PASSWORDLESS
  [[ -z "${MAC_RELEASE_CODESIGN_KEYCHAIN_TIMEOUT:-}" ]] || export MAC_RELEASE_CODESIGN_KEYCHAIN_TIMEOUT
  [[ -z "${MAC_RELEASE_CODESIGN_CANARY_TIMEOUT:-}" ]] || export MAC_RELEASE_CODESIGN_CANARY_TIMEOUT
  CODESIGN_IDENTITY=$MAC_RELEASE_CODESIGN_IDENTITY
  export CODESIGN_IDENTITY
}

mac_release_codesign_run() {
  local load_mode=codesign-only
  if [[ "${1:-}" == "--with-package-secrets" ]]; then
    load_mode=all
    shift
  fi
  [[ "${1:-}" == "--" ]] && shift
  [[ "$#" -gt 0 ]] ||
    mac_release_die "Usage: mac-release codesign-run [--with-package-secrets] -- <command> [args...]"

  mac_release_load_codesign_config
  mac_release_load_1password_env "$load_mode"
  if [[ "$load_mode" == "codesign-only" ]]; then
    local release_op_field
    for release_op_field in ${MAC_RELEASE_OP_FIELDS:-}; do
      [[ "$release_op_field" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        mac_release_die "Invalid package secret environment name: $release_op_field"
      unset "$release_op_field"
    done
  fi
  # shellcheck disable=SC2329 # invoked via EXIT trap
  cleanup_codesign_run() {
    local rc=$?
    if ! mac_release_restore_codesign_keychains; then
      sleep 1
      mac_release_restore_codesign_keychains || true
      [[ "$rc" -ne 0 ]] || rc=1
    fi
    exit "$rc"
  }
  trap cleanup_codesign_run EXIT

  mac_release_prepare_codesign_keychain
  local command_rc=0 cleanup_rc=0
  "$@" || command_rc=$?
  if ! mac_release_restore_codesign_keychains; then
    sleep 1
    mac_release_restore_codesign_keychains || cleanup_rc=$?
  fi
  if [[ "$cleanup_rc" == "0" ]]; then
    trap - EXIT
  else
    return "$cleanup_rc"
  fi
  return "$command_rc"
}

mac_release_release() {
  mac_release_load
  require_bin git gh
  local release_branch current_branch
  release_branch=${MAC_RELEASE_RELEASE_BRANCH:-main}
  current_branch=$(git branch --show-current)
  [[ "$current_branch" == "$release_branch" ]] || mac_release_die "Release must run on $release_branch; current branch is ${current_branch:-detached}"
  require_clean_worktree
  local pre_release_head
  pre_release_head=$(git rev-parse HEAD)
  ensure_changelog_finalized "$MARKETING_VERSION"
  ensure_appcast_monotonic "$APPCAST" "$MARKETING_VERSION" "$BUILD_NUMBER"
  mac_release_load_1password_env
  mac_release_run_cmd "precheck" "${MAC_RELEASE_PRECHECK:-}"
  KEY_ARGS=()
  local key_file="" notes_md="" release_created=0 tag_created=0 tag_pushed=0 appcast_committed=0 appcast_pushed=0
  # shellcheck disable=SC2329 # invoked via EXIT trap
  cleanup_release() {
    local rc=$?
    if ! mac_release_restore_codesign_keychains; then
      sleep 1
      if ! mac_release_restore_codesign_keychains; then
        echo "ERROR: Developer ID keychain cleanup failed after retry" >&2
        if [[ -n "${MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN:-}" && "${MAC_RELEASE_CODESIGN_PASSWORDLESS_ACTIVE:-0}" != "1" ]]; then
          security lock-keychain "$MAC_RELEASE_ACTIVE_CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
        fi
      fi
    fi
    [[ -n "${key_file:-}" ]] && rm -f "$key_file"
    [[ -n "${notes_md:-}" ]] && rm -f "$notes_md"
    if [[ "$rc" -ne 0 && "${appcast_pushed:-0}" != "1" ]]; then
      if [[ "${release_created:-0}" == "1" ]]; then
        gh release delete "$TAG" --repo "$MAC_RELEASE_REPO" --cleanup-tag -y >/dev/null 2>&1 || true
      elif [[ "${tag_pushed:-0}" == "1" ]]; then
        git push origin --delete "$TAG" >/dev/null 2>&1 || true
      fi
      [[ "${tag_created:-0}" == "1" ]] && git tag -d "$TAG" >/dev/null 2>&1 || true
      if [[ "${appcast_committed:-0}" == "1" ]]; then
        git reset --hard "$pre_release_head" >/dev/null 2>&1 || true
      fi
    fi
    exit "$rc"
  }
  trap cleanup_release EXIT
  mac_release_key_args_and_validate KEY_ARGS key_file
  clear_sparkle_caches "$MAC_RELEASE_BUNDLE_ID"
  mac_release_prepare_codesign_keychain
  mac_release_run_cmd "package" "$MAC_RELEASE_PACKAGE_CMD"
  mac_release_restore_codesign_keychains
  notes_md=$(mktemp "/tmp/${APP_NAME}-notes.XXXXXX")
  extract_notes_from_changelog "$MARKETING_VERSION" "$notes_md"
  if [[ -n "$key_file" ]]; then
    SPARKLE_PRIVATE_KEY_FILE="$key_file" "$0" make-appcast "$APP_ZIP" "$FEED_URL"
  else
    env -u SPARKLE_PRIVATE_KEY_FILE "$0" make-appcast "$APP_ZIP" "$FEED_URL"
  fi
  git add "$APPCAST"
  git commit -m "docs: update appcast for ${MARKETING_VERSION}"
  appcast_committed=1

  local tag_args=() push_tag_args=()
  [[ "${MAC_RELEASE_TAG_FORCE:-1}" == "1" ]] && tag_args+=(-f) && push_tag_args+=(-f)
  if [[ "${MAC_RELEASE_TAG_SIGNED:-0}" == "1" ]]; then
    git tag -s ${tag_args[@]+"${tag_args[@]}"} -m "${APP_NAME} ${MARKETING_VERSION}" "$TAG"
  elif [[ "${MAC_RELEASE_TAG_ANNOTATED:-1}" == "1" ]]; then
    git tag ${tag_args[@]+"${tag_args[@]}"} -m "${APP_NAME} ${MARKETING_VERSION}" "$TAG"
  else
    git tag --no-sign ${tag_args[@]+"${tag_args[@]}"} "$TAG"
  fi
  tag_created=1
  git push ${push_tag_args[@]+"${push_tag_args[@]}"} origin "$TAG"
  tag_pushed=1
  gh release create "$TAG" --repo "$MAC_RELEASE_REPO" --title "${APP_NAME} ${MARKETING_VERSION}" --notes-file "$notes_md"
  release_created=1
  local release_assets=("$APP_ZIP")
  [[ -n "$DSYM_ZIP" ]] && release_assets+=("$DSYM_ZIP")
  gh release upload "$TAG" "${release_assets[@]}" --repo "$MAC_RELEASE_REPO"
  if [[ -n "$key_file" ]]; then
    SPARKLE_PRIVATE_KEY_FILE="$key_file" "$0" verify-appcast "$MARKETING_VERSION"
  else
    env -u SPARKLE_PRIVATE_KEY_FILE "$0" verify-appcast "$MARKETING_VERSION"
  fi
  wait_for_assets "$TAG" "$ARTIFACT_PREFIX"
  git push origin "HEAD:$release_branch"
  appcast_pushed=1
  if [[ "${MAC_RELEASE_RUN_SPARKLE_UPDATE_TEST:-${RUN_SPARKLE_UPDATE_TEST:-0}}" == "1" && -x "$ROOT/Scripts/test_live_update.sh" ]]; then
    local prev_tag
    prev_tag=$(git tag --sort=-v:refname | sed -n '2p')
    [[ -n "$prev_tag" ]] || mac_release_die "Sparkle update test requested but no previous tag found"
    "$ROOT/Scripts/test_live_update.sh" "$prev_tag" "$TAG"
  fi
  trap - EXIT
  [[ -n "${key_file:-}" ]] && rm -f "$key_file"
  [[ -n "${notes_md:-}" ]] && rm -f "$notes_md"
  echo "Release ${MARKETING_VERSION} complete."
}
