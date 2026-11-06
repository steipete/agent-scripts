#!/bin/bash

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

usage() {
  printf 'usage: %s [--cli-only] [--repair] [--op-source PATH]\n' "$0" >&2
}

repair=false
cli_only=false
op_source=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair)
      repair=true
      shift
      ;;
    --cli-only)
      cli_only=true
      shift
      ;;
    --op-source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      op_source="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$repair" == true && "$cli_only" == true ]]; then
  printf 'op-profile: --cli-only is a read-only audit mode\n' >&2
  exit 2
fi

profile="$HOME/.profile"
zprofile="$HOME/.zprofile"
config_dir="$HOME/.config"
token_dir="$HOME/.config/op"
token_file="$token_dir/molty-service-account-token"
bin_dir="$HOME/bin"
op_home="$bin_dir/op"
op_compat="/opt/homebrew/bin/op"
expected_team="2BUA8C4S2C"
expected_identifier="com.1password.op"
expected_requirement='identifier "com.1password.op" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2BUA8C4S2C"'
begin_marker="# BEGIN Codex-managed OP_SERVICE_ACCOUNT_TOKEN"
end_marker="# END Codex-managed OP_SERVICE_ACCOUNT_TOKEN"
safe_assignment_pattern='^[[:space:]]*(export[[:space:]]+)?OP_SERVICE_ACCOUNT_TOKEN=([A-Za-z0-9_.\/+,:=-]+|"[A-Za-z0-9_.\/+,:=-]*")[[:space:]]*$'

op_team() {
  codesign -dv --verbose=4 "$1" 2>&1 |
    sed -n 's/^TeamIdentifier=//p' |
    head -n 1
}

op_identifier() {
  codesign -dv --verbose=4 "$1" 2>&1 |
    sed -n 's/^Identifier=//p' |
    head -n 1
}

verify_op() {
  local candidate=$1
  local host_arch
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] || return 1
  [[ "$(stat -f '%u' "$candidate" 2>/dev/null || true)" == "$(id -u)" ]] || return 1
  [[ "$(stat -f '%l' "$candidate" 2>/dev/null || true)" == 1 ]] || return 1
  path_mode_exclusively_writable "$candidate" || return 1
  ! path_has_acl "$candidate" || return 1
  codesign -v --strict -R="$expected_requirement" "$candidate" >/dev/null 2>&1 || return 1
  [[ "$(op_team "$candidate")" == "$expected_team" ]] || return 1
  [[ "$(op_identifier "$candidate")" == "$expected_identifier" ]] || return 1
  host_arch=$(uname -m)
  lipo -archs "$candidate" 2>/dev/null |
    tr ' ' '\n' |
    grep -Fqx "$host_arch"
}

path_has_acl() {
  # macOS exposes file ACL entries through ls -e; find has no equivalent predicate.
  # shellcheck disable=SC2012
  ls -lde "$1" 2>/dev/null |
    awk 'NR > 1 { found=1 } END { exit found ? 0 : 1 }'
}

path_mode_exclusively_writable() {
  local path_mode
  path_mode=$(stat -f '%Lp' "$1" 2>/dev/null || true)
  [[ "$path_mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$path_mode & 8#022) == 0 ))
}

bin_dir_secure() {
  [[ -d "$bin_dir" && ! -L "$bin_dir" ]] || return 1
  [[ "$(stat -f '%u' "$bin_dir" 2>/dev/null || true)" == "$(id -u)" ]] || return 1
  path_mode_exclusively_writable "$bin_dir" || return 1
  ! path_has_acl "$bin_dir"
}

startup_file_secure() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  [[ "$(stat -f '%u' "$1" 2>/dev/null || true)" == "$(id -u)" ]] || return 1
  [[ "$(stat -f '%l' "$1" 2>/dev/null || true)" == 1 ]] || return 1
  path_mode_exclusively_writable "$1" || return 1
  ! path_has_acl "$1"
}

zprofile_loads_profile_token() {
  startup_file_secure "$zprofile" || return 1
  # A commented-out command is not a loader, and naming the token is not a read.
  # shellcheck disable=SC2016
  awk '
    function shell_code(line,    i, n, c, q) {
      n = length(line)
      q = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "\047") {
          if (c == "\047") q = ""
        } else if (q == "\"") {
          if (c == "\\") i++
          else if (c == "\"") q = ""
        } else if (c == "\047" || c == "\"") {
          q = c
        } else if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]|&;<>()`]/)) {
          return substr(line, 1, i - 1)
        }
      }
      return line
    }

    function word_end(text, pos) {
      return pos > length(text) || substr(text, pos, 1) !~ /[[:alnum:]_.\/-]/
    }

    function token_word(text, pos,    plain, tilde, quoted) {
      plain = "$HOME/.config/op/molty-service-account-token"
      tilde = "~/.config/op/molty-service-account-token"
      quoted = "\"" plain "\""
      if (substr(text, pos, length(quoted)) == quoted && word_end(text, pos + length(quoted)))
        return 1
      if (substr(text, pos, length(plain)) == plain && word_end(text, pos + length(plain)))
        return 1
      if (substr(text, pos, length(tilde)) == tilde && word_end(text, pos + length(tilde)))
        return 1
      return 0
    }

    function reads_token(text,    i, n, j, prev) {
      n = length(text)
      for (i = 1; i <= n; i++) {
        if (substr(text, i, 1) != "<") continue
        if (substr(text, i + 1, 1) == "<") {
          i++
          continue
        }
        j = i + 1
        if (substr(text, j, 1) == "&" || substr(text, j, 1) == "(") continue
        if (substr(text, j, 1) == ">") j++
        while (j <= n && substr(text, j, 1) ~ /[[:space:]]/) j++
        if (token_word(text, j)) return 1
      }
      for (i = 1; i <= n; i++) {
        prev = (i == 1) ? "" : substr(text, i - 1, 1)
        if (i > 1 && prev !~ /[[:space:]|;|&<>()`"\047\/]/) continue
        if (substr(text, i, 3) != "cat") continue
        if (i + 3 <= n && substr(text, i + 3, 1) !~ /[[:space:]]/) continue
        j = i + 3
        while (j <= n && substr(text, j, 1) ~ /[[:space:]]/) j++
        if (token_word(text, j)) return 1
      }
      return 0
    }

    BEGIN { found = 0 }
    {
      code = shell_code($0)
      if (code ~ /^[[:space:]]*(source|\.)[[:space:]]+"?[$]HOME\/\.profile"?[[:space:]]*$/ ||
          code ~ /^[[:space:]]*(source|\.)[[:space:]]+~\/\.profile[[:space:]]*$/) found = 1
      else if (code ~ /^[[:space:]]*(source|\.)[[:space:]]+"[$]HOME\/\.config\/op\/molty-service-account-token"[[:space:]]*$/ ||
               code ~ /^[[:space:]]*(source|\.)[[:space:]]+[$]HOME\/\.config\/op\/molty-service-account-token[[:space:]]*$/ ||
               code ~ /^[[:space:]]*(source|\.)[[:space:]]+~\/\.config\/op\/molty-service-account-token[[:space:]]*$/) found = 1
      else if (code ~ /^[[:space:]]*eval[[:space:]]/ && reads_token(code)) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$zprofile"
}

token_path_ancestors_safe() {
  local physical_home
  [[ -d "$HOME" && ! -L "$HOME" ]] || return 1
  physical_home=$(cd "$HOME" && pwd -P) || return 1
  [[ "$physical_home" == "${HOME%/}" ]] || return 1
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
  [[ -d "$token_dir" && ! -L "$token_dir" ]]
}

canonical_profile_block() {
  # These are literal profile lines; expansion must happen when the profile is sourced.
  # shellcheck disable=SC2016
  printf '%s\n' \
    "$begin_marker" \
    '# Secret lives outside Git; provision this file with mode 0600.' \
    'if [[ -r "$HOME/.config/op/molty-service-account-token" ]]; then' \
    $'\texport OP_SERVICE_ACCOUNT_TOKEN="$(< "$HOME/.config/op/molty-service-account-token")"' \
    'fi' \
    "$end_marker"
}

managed_markers_valid() {
  [[ ! -f "$profile" ]] && return 0
  awk -v begin="$begin_marker" -v end="$end_marker" '
    index($0, "BEGIN Codex-managed OP_SERVICE_ACCOUNT_TOKEN") {
      if ($0 != begin || seen_begin || seen_end) bad=1
      seen_begin=1
      inside=1
    }
    index($0, "END Codex-managed OP_SERVICE_ACCOUNT_TOKEN") {
      if ($0 != end || !inside || seen_end) bad=1
      seen_end=1
      inside=0
    }
    END {
      if (bad || seen_begin != seen_end || inside) exit 1
    }
  ' "$profile"
}

canonical_profile_block_present() {
  local actual expected
  [[ -f "$profile" ]] || return 1
  managed_markers_valid || return 1
  actual=$(awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { inside=1 }
    inside { print }
    $0 == end && inside { inside=0 }
  ' "$profile")
  expected=$(canonical_profile_block)
  [[ "$actual" == "$expected" ]]
}

external_profile_reference_present() {
  [[ -f "$profile" ]] || return 1
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { inside=1 }
    !inside && index($0, "OP_SERVICE_ACCOUNT_TOKEN") { found=1 }
    $0 == end && inside { inside=0 }
    END { exit found ? 0 : 1 }
  ' "$profile"
}

unsafe_external_profile_reference_present() {
  [[ -f "$profile" ]] || return 1
  awk -v begin="$begin_marker" -v end="$end_marker" -v safe="$safe_assignment_pattern" '
    $0 == begin { inside=1 }
    !inside && index($0, "OP_SERVICE_ACCOUNT_TOKEN") &&
      $0 !~ safe { unsafe=1 }
    $0 == end && inside { inside=0 }
    END { exit unsafe ? 0 : 1 }
  ' "$profile"
}

profile_counts() {
  if [[ ! -f "$profile" ]]; then
    printf '0 0 0 0\n'
    return
  fi
  awk '
    $0 == "# BEGIN Codex-managed OP_SERVICE_ACCOUNT_TOKEN" { begin++ }
    $0 == "# END Codex-managed OP_SERVICE_ACCOUNT_TOKEN" { end++ }
    /^[[:space:]]*(export[[:space:]]+)?OP_SERVICE_ACCOUNT_TOKEN=/ {
      exact++
      if ($0 ~ /\.config\/op\/molty-service-account-token/) file_backed++
    }
    END { printf "%d %d %d %d\n", begin+0, end+0, exact+0, file_backed+0 }
  ' "$profile"
}

audit() {
  local failures=0
  local op_state=missing compat_state=missing token_state=missing profile_state=missing zprofile_state=missing
  local begin_count end_count exact_count file_backed_count token_mode token_owner token_links expected_owner

  if bin_dir_secure && verify_op "$op_home"; then
    op_state=current
  elif [[ -e "$op_home" ]]; then
    op_state=invalid
    failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi

  if [[ -L "$op_compat" && "$(readlink "$op_compat")" == "$op_home" ]]; then
    compat_state=current
  elif [[ -e "$op_compat" || -L "$op_compat" ]]; then
    compat_state=conflict
    failures=$((failures + 1))
  else
    failures=$((failures + 1))
  fi

  if [[ "$cli_only" == true ]]; then
    printf 'op-cli host=%s op=%s compat=%s\n' \
      "$(scutil --get LocalHostName 2>/dev/null || hostname)" "$op_state" "$compat_state"
    [[ "$failures" -eq 0 ]]
    return
  fi

  if ! token_path_ancestors_safe; then
    token_state=unsafe-path
    failures=$((failures + 1))
  elif [[ -f "$token_file" && ! -L "$token_file" && -s "$token_file" ]]; then
    token_mode=$(stat -f '%Lp' "$token_file" 2>/dev/null || true)
    token_owner=$(stat -f '%u' "$token_file" 2>/dev/null || true)
    token_links=$(stat -f '%l' "$token_file" 2>/dev/null || true)
    expected_owner=$(id -u)
    if [[ "$token_mode" != 600 ]]; then
      token_state="mode-${token_mode:-unknown}"
      failures=$((failures + 1))
    elif [[ "$token_owner" != "$expected_owner" ]]; then
      token_state=owner-mismatch
      failures=$((failures + 1))
    elif [[ "$token_links" != 1 ]]; then
      token_state=hardlinked
      failures=$((failures + 1))
    elif [[ ! -r "$token_file" ]]; then
      token_state=unreadable
      failures=$((failures + 1))
    elif path_has_acl "$token_file"; then
      token_state=acl-present
      failures=$((failures + 1))
    else
      token_state=current
    fi
  else
    failures=$((failures + 1))
  fi

  read -r begin_count end_count exact_count file_backed_count <<< "$(profile_counts)"
  if [[ "$begin_count" == 1 && "$end_count" == 1 && "$exact_count" == 1 && "$file_backed_count" == 1 ]] &&
    startup_file_secure "$profile" && canonical_profile_block_present && ! external_profile_reference_present; then
    profile_state=current
  else
    profile_state="drift-${begin_count}-${end_count}-${exact_count}-${file_backed_count}"
    failures=$((failures + 1))
  fi

  if zprofile_loads_profile_token; then
    zprofile_state=current
  else
    zprofile_state=drift
    failures=$((failures + 1))
  fi

  printf 'op-profile host=%s op=%s compat=%s token_file=%s profile=%s zprofile=%s\n' \
    "$(scutil --get LocalHostName 2>/dev/null || hostname)" \
    "$op_state" "$compat_state" "$token_state" "$profile_state" "$zprofile_state"
  [[ "$failures" -eq 0 ]]
}

if [[ "$repair" == false ]]; then
  audit
  exit $?
fi

if [[ -e "$profile" || -L "$profile" ]]; then
  if [[ -L "$profile" ]]; then
    printf 'op-profile: refusing symlinked profile; update its canonical source manually: %s\n' "$profile" >&2
    exit 2
  fi
  if [[ ! -f "$profile" ]]; then
    printf 'op-profile: refusing non-regular profile path: %s\n' "$profile" >&2
    exit 2
  fi
fi
if [[ ! -f "$zprofile" || -L "$zprofile" ]]; then
  printf 'op-profile: refusing missing, non-regular, or symlinked zprofile: %s\n' "$zprofile" >&2
  exit 2
fi
if ! zprofile_loads_profile_token; then
  printf 'op-profile: refusing zprofile without a secure .profile token loader: %s\n' "$zprofile" >&2
  exit 2
fi

read -r begin_count end_count _ _ <<< "$(profile_counts)"
if ! managed_markers_valid || [[ "$begin_count" != "$end_count" || "$begin_count" -gt 1 ]]; then
  printf 'op-profile: refusing malformed managed block begin=%s end=%s\n' "$begin_count" "$end_count" >&2
  exit 2
fi
if unsafe_external_profile_reference_present; then
  printf 'op-profile: refusing unrecognized OP_SERVICE_ACCOUNT_TOKEN reference outside managed block\n' >&2
  exit 2
fi

for startup_file in "$profile" "$zprofile"; do
  if [[ -e "$startup_file" ]]; then
    startup_owner=$(stat -f '%u' "$startup_file" 2>/dev/null || true)
    startup_links=$(stat -f '%l' "$startup_file" 2>/dev/null || true)
    if [[ "$startup_owner" != "$(id -u)" || "$startup_links" != 1 ]]; then
      printf 'op-profile: refusing startup file without exclusive current-user ownership: %s\n' "$startup_file" >&2
      exit 2
    fi
    if ! chmod -N "$startup_file"; then
      printf 'op-profile: unable to remove ACLs from startup file: %s\n' "$startup_file" >&2
      exit 2
    fi
    chmod go-w "$startup_file"
  fi
done

umask 077
if [[ ! -d "$HOME" || -L "$HOME" || "$(cd "$HOME" && pwd -P)" != "${HOME%/}" ]]; then
  printf 'op-profile: refusing non-canonical or symlinked home path: %s\n' "$HOME" >&2
  exit 2
fi
if [[ -e "$bin_dir" || -L "$bin_dir" ]]; then
  if [[ ! -d "$bin_dir" || -L "$bin_dir" ]]; then
    printf 'op-profile: refusing non-directory or symlinked bin path: %s\n' "$bin_dir" >&2
    exit 2
  fi
else
  mkdir "$bin_dir"
fi
bin_dir_owner=$(stat -f '%u' "$bin_dir" 2>/dev/null || true)
if [[ "$bin_dir_owner" != "$(id -u)" ]]; then
  printf 'op-profile: refusing bin directory owned by another account: %s\n' "$bin_dir" >&2
  exit 2
fi
if ! chmod -N "$bin_dir"; then
  printf 'op-profile: unable to remove ACLs from bin directory: %s\n' "$bin_dir" >&2
  exit 2
fi
chmod go-w "$bin_dir"
if [[ -e "$config_dir" || -L "$config_dir" ]]; then
  if [[ ! -d "$config_dir" || -L "$config_dir" ]]; then
    printf 'op-profile: refusing non-directory or symlinked config parent: %s\n' "$config_dir" >&2
    exit 2
  fi
else
  mkdir "$config_dir"
fi
config_dir_owner=$(stat -f '%u' "$config_dir" 2>/dev/null || true)
if [[ "$config_dir_owner" != "$(id -u)" ]]; then
  printf 'op-profile: refusing config directory owned by another account: %s\n' "$config_dir" >&2
  exit 2
fi
if [[ -e "$token_dir" || -L "$token_dir" ]]; then
  if [[ ! -d "$token_dir" || -L "$token_dir" ]]; then
    printf 'op-profile: refusing non-directory token parent: %s\n' "$token_dir" >&2
    exit 2
  fi
else
  mkdir -p "$token_dir"
fi
token_dir_owner=$(stat -f '%u' "$token_dir" 2>/dev/null || true)
if [[ "$token_dir_owner" != "$(id -u)" ]]; then
  printf 'op-profile: refusing token directory owned by another account: %s\n' "$token_dir" >&2
  exit 2
fi
if ! chmod -N "$token_dir"; then
  printf 'op-profile: unable to remove ACLs from token directory: %s\n' "$token_dir" >&2
  exit 2
fi
chmod 700 "$token_dir"

if [[ -e "$token_file" || -L "$token_file" ]]; then
  if [[ ! -f "$token_file" || -L "$token_file" ]]; then
    printf 'op-profile: refusing non-regular token path: %s\n' "$token_file" >&2
    exit 2
  fi
fi

if [[ -e "$token_file" || -L "$token_file" ]]; then
  token_owner=$(stat -f '%u' "$token_file" 2>/dev/null || true)
  if [[ "$token_owner" != "$(id -u)" ]]; then
    printf 'op-profile: refusing token file owned by another account: %s\n' "$token_file" >&2
    exit 2
  fi
  token_links=$(stat -f '%l' "$token_file" 2>/dev/null || true)
  if [[ "$token_links" != 1 ]]; then
    printf 'op-profile: refusing hard-linked token file: %s\n' "$token_file" >&2
    exit 2
  fi
  if ! chmod -N "$token_file"; then
    printf 'op-profile: unable to remove ACLs from token file: %s\n' "$token_file" >&2
    exit 2
  fi
  chmod 600 "$token_file"
fi

if [[ ! -s "$token_file" ]]; then
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    printf 'op-profile: token file is missing and OP_SERVICE_ACCOUNT_TOKEN is unavailable\n' >&2
    exit 2
  fi
  printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" > "$token_file"
  chmod 600 "$token_file"
fi

if [[ -L "$op_home" ]]; then
  if [[ -z "$op_source" ]] || ! verify_op "$op_source"; then
    printf 'op-profile: stable op is symlinked; pass --op-source with a verified native binary\n' >&2
    exit 2
  fi
  op_tmp=$(mktemp "$bin_dir/.op.fleet.XXXXXX")
  install -m 755 "$op_source" "$op_tmp"
  mv -fh "$op_tmp" "$op_home"
elif [[ ! -e "$op_home" ]]; then
  if [[ -z "$op_source" ]]; then
    printf 'op-profile: stable op is missing; pass --op-source with a verified binary\n' >&2
    exit 2
  fi
  if ! verify_op "$op_source"; then
    printf 'op-profile: refusing unsigned or unexpected op source: %s\n' "$op_source" >&2
    exit 2
  fi
  install -m 755 "$op_source" "$op_home"
elif [[ ! -f "$op_home" ]]; then
  printf 'op-profile: refusing non-regular stable op path: %s\n' "$op_home" >&2
  exit 2
fi

op_owner=$(stat -f '%u' "$op_home" 2>/dev/null || true)
op_links=$(stat -f '%l' "$op_home" 2>/dev/null || true)
if [[ "$op_owner" != "$(id -u)" || "$op_links" != 1 ]]; then
  printf 'op-profile: refusing stable op without exclusive current-user ownership: %s\n' "$op_home" >&2
  exit 2
fi
if ! chmod -N "$op_home"; then
  printf 'op-profile: unable to remove ACLs from stable op: %s\n' "$op_home" >&2
  exit 2
fi
chmod go-w "$op_home"

if ! verify_op "$op_home"; then
  printf 'op-profile: refusing invalid stable op binary: %s\n' "$op_home" >&2
  exit 2
fi

if [[ -e "$op_compat" && ! -L "$op_compat" ]]; then
  printf 'op-profile: refusing non-symlink compatibility path: %s\n' "$op_compat" >&2
  exit 2
fi
mkdir -p "$(dirname "$op_compat")"
ln -sfn "$op_home" "$op_compat"

profile_tmp=$(mktemp "$HOME/.profile.fleet-op.XXXXXX")
if [[ -f "$profile" ]]; then
  awk -v safe="$safe_assignment_pattern" '
    /BEGIN Codex-managed OP_SERVICE_ACCOUNT_TOKEN/ { managed=1; next }
    /END Codex-managed OP_SERVICE_ACCOUNT_TOKEN/ { managed=0; next }
    managed { next }
    $0 ~ safe { next }
    { print }
  ' "$profile" > "$profile_tmp"
  profile_mode=$(stat -f '%Lp' "$profile" 2>/dev/null || printf '600')
else
  : > "$profile_tmp"
  profile_mode=600
fi

{
  printf '\n'
  canonical_profile_block
} >> "$profile_tmp"
chmod "$profile_mode" "$profile_tmp"
mv "$profile_tmp" "$profile"

audit
