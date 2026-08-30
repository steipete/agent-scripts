#!/bin/bash
set -u -o pipefail

agent_skills="$HOME/Projects/agent-scripts/skills"
manager_skills="$HOME/Projects/manager/skills"
codex_root="$HOME/.codex/skills"
claude_root="$HOME/.claude/skills"
agents_md="$HOME/Projects/agent-scripts/AGENTS.MD"
repair=${1:-}
failures=0

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$repair" != "--repair" ]; }; then
  printf 'usage: %s [--repair]\n' "$0" >&2
  exit 2
fi

if [ "$repair" = "--repair" ]; then
  sync="$HOME/Projects/agent-scripts/scripts/sync-skills"
  for required_root in "$agent_skills" "$manager_skills"; do
    if [ ! -d "$required_root" ]; then
      printf 'skill-links\tstatus=error\treason=canonical-root-missing\tpath=%s\n' "$required_root" >&2
      exit 2
    fi
  done
  if [ ! -x "$sync" ]; then
    printf 'skill-links\tstatus=error\treason=sync-script-missing\tpath=%s\n' "$sync" >&2
    exit 2
  fi
  sync_exit=0
  "$sync" || sync_exit=$?
  if [ "$sync_exit" -ne 0 ]; then
    printf 'skill-links\tstatus=error\treason=sync-failed\texit=%s\n' "$sync_exit" >&2
    exit "$sync_exit"
  fi
fi

check_link() {
  expected=$1
  link_path=$2
  actual=$(readlink "$link_path" 2>/dev/null || true)
  if [ "$actual" = "$expected" ] && [ -e "$link_path" ]; then
    return 0
  fi
  printf 'skill-links-drift\tpath=%s\texpected=%s\tactual=%s\n' "$link_path" "$expected" "${actual:-missing-or-not-symlink}"
  failures=$((failures + 1))
}

check_link "$agent_skills" "$codex_root/agent-scripts"
check_link "$manager_skills" "$codex_root/manager"
check_link "$agents_md" "$HOME/.codex/AGENTS.md"
check_link "$agents_md" "$HOME/.claude/CLAUDE.md"
check_link "$agents_md" "$HOME/.claude/AGENTS.md"

if [ -L "$claude_root" ] || [ ! -d "$claude_root" ]; then
  printf 'skill-links-drift\tpath=%s\texpected=real-directory\n' "$claude_root"
  failures=$((failures + 1))
fi

check_skill_root() {
  root=$1
  entry=
  name=
  expected=
  for entry in "$root"/*; do
    [ -f "$entry/SKILL.md" ] || continue
    name=$(basename "$entry")
    expected=$entry
    if [ "$root" = "$manager_skills" ] && [ -f "$agent_skills/$name/SKILL.md" ]; then
      continue
    fi
    check_link "$expected" "$claude_root/$name"
  done
}

[ ! -d "$agent_skills" ] || check_skill_root "$agent_skills"
[ ! -d "$manager_skills" ] || check_skill_root "$manager_skills"

broken=0
for link_path in "$claude_root"/* "$claude_root"/.[!.]*; do
  [ -L "$link_path" ] || continue
  [ ! -e "$link_path" ] || continue
  printf 'skill-links-drift\tpath=%s\treason=broken-symlink\n' "$link_path"
  broken=$((broken + 1))
done
failures=$((failures + broken))

# Narrow ancestor-loop detection, not an exhaustive symlink graph validator.
# A nested link resolving successfully to its real parent is still a loop.
for entry in "$claude_root"/* "$claude_root"/.[!.]* "$claude_root"/..?*; do
  [ ! -L "$entry" ] && [ -d "$entry" ] || continue
  name=${entry##*/}
  nested="$entry/$name"
  if [ -L "$nested" ] && [ "$nested" -ef "$entry" ]; then
    printf 'skill-links-drift\tpath=%s\treason=nested-self-link\n' "$nested"
    failures=$((failures + 1))
  fi
done

claude_count=$(find "$claude_root" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
if [ "$failures" -eq 0 ]; then
  printf 'skill-links\tstatus=current\tclaude_links=%s\n' "$claude_count"
  exit 0
fi

printf 'skill-links\tstatus=drift\tfailures=%s\tclaude_links=%s\n' "$failures" "$claude_count"
exit 1
