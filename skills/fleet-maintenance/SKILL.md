---
name: fleet-maintenance
description: "Mac fleet inventory and upkeep with full/worker profiles: collect installed apps and packages, compare desired versus observed state, audit local-account escrow references, update Homebrew/global packages, safely sync repos and Xcode, and report disk, service, backup, update, and security health."
---

# Fleet Maintenance

Maintain Peter's Macs while protecting ambiguous local work. Package updates are explicitly allowed during active sessions and may disrupt the software being upgraded. Use `$remote-mac` for inventory/SSH and `$xcode-sync` for all Xcode work.

## Desired state

- Read `~/Projects/manager/fleet/inventory.json` for desired software and local-account escrow references. Read `references/fleet-schema.md` before changing its schema or adopting packages.
- Keep exactly two profiles unless Peter explicitly changes the model:
  - `full`: daily-driver Macs with the complete development, communication, media, and agentic toolset.
  - `worker`: lean remote Macs that mainly run Codex, Claude, OpenClaw nodes, and supporting agent infrastructure.
- Treat profile policy as `minimum`: install required entries and report extras without removing them. Never silently turn observed software into desired state.
- Keep topology, SSH routing, and handed-off status in `~/Projects/manager/computers.yaml`. Do not duplicate live topology in this skill.
- Keep passwords, recovery keys, and private keys in 1Password. The inventory stores opaque item IDs only. Invoke `$one-password` before any `op` command; a `pending` reference is not an error during package maintenance.
- Require the classic OpenSSH mesh named by `ssh_mesh` on both profiles. The manager fleet setup document owns the canonical peer list and live proof. Use the symmetric Tailscale TCP 22 grant plus per-host `authorized_keys`; macOS GUI Tailscale clients cannot act as Tailscale SSH servers. Distribute public keys only, keep private keys host-local, verify both directions with `BatchMode=yes` and a finite timeout, and leave offline or provider-blocked directions pending.
- Require the stable 1Password CLI integrity baseline on every fleet Mac. Require the file-backed service-account profile block unless that host has a documented `requirement_exceptions` security boundary in inventory. Audit eligible hosts with `scripts/op-profile-audit.sh`; audit token-exempt hosts with `scripts/op-profile-audit.sh --cli-only`. Repair only after `$one-password` is loaded and the mode-0600 token file is provisioned; never print or store the token in inventory.
- Require the agent skill mirror on every fleet Mac. Audit it with `scripts/agent-skill-links-audit.sh`; its `--repair` invokes broad canonical sync only when both canonical repos exist. Sync preserves real directories and files, accepting same-directory local ownership and reporting other real destination conflicts. For `reason=nested-self-link`, invoke the reviewed sync owner directly by absolute path with `--repair-nested-self-links --dry-run -- NAME...`, then omit `--dry-run` to remove only validated nested leaves; preserve the real Claude skill directories and Codex backlinks. This narrow loop check is not an exhaustive graph validator. See `references/fleet-schema.md` for scope and `~/Projects/manager/docs/fleet-setup.md` for fleet setup.
- Require the shared global Git ignore on every fleet Mac. Audit it with `scripts/global-gitignore-audit.sh`; `--repair` creates `~/.config/git/ignore`, preserves unrelated entries, adds the inventory's macOS metadata patterns, and points `core.excludesFile` at it. An already-configured alternate excludes file requires manual review so existing rules are never discarded.
- Require Claude Code and Claude Desktop coding sessions to omit AI attribution. Audit `~/.claude/settings.json` with `scripts/claude-attribution-audit.sh`; `--repair` preserves unrelated settings while disabling commit trailers, pull-request footers, and remote-session links.
- Require the official Codex and Claude Code CLIs on both profiles. Package ownership comes from the profile's `codex` and `claude-code` Homebrew casks; the separate `claude` cask is Claude Desktop and does not satisfy the CLI requirement. Audit versions and non-interactive authentication with `scripts/agent-cli-audit.sh`; use `--live` for bounded, tool-free, non-persistent model turns. Never copy normal Claude OAuth credentials between Macs: refresh each host independently through `$anthropic` and leave locked-Keychain, account-selection, or offline cases pending.
- Require Octopool as the GitHub cache on both profiles with `requirements.github_cache: "octopool"`. Package presence alone is insufficient: `scripts/octopool-audit.sh` must prove that non-interactive and login zsh resolve `gh` through the Octopool shim, the client login has complete identity metadata, and every configured pool identity is healthy. Use `--repair` to log in through the existing authenticated stable-path GitHub CLI, install the zsh shim, and repair macOS login PATH ordering when needed; it never installs packages or prints credentials.

Use the deterministic profile tool:

```bash
node skills/fleet-maintenance/scripts/fleet-profile.mjs collect
node skills/fleet-maintenance/scripts/fleet-profile.mjs \
  plan --fleet ~/Projects/manager/fleet/inventory.json \
  --host mac-studio-sf --snapshot /path/to/mac-studio-sf.json
node skills/fleet-maintenance/scripts/fleet-profile.mjs \
  diff --source /path/to/macbook-pro.json --target /path/to/mac-studio-sf.json
node skills/fleet-maintenance/scripts/fleet-profile.mjs \
  brewfile --fleet ~/Projects/manager/fleet/inventory.json --host mac-studio-sf
node skills/fleet-maintenance/scripts/fleet-profile.mjs \
  validate --fleet ~/Projects/manager/fleet/inventory.json
skills/fleet-maintenance/scripts/agent-skill-links-audit.sh
skills/fleet-maintenance/scripts/global-gitignore-audit.sh --host mac-studio-sf
skills/fleet-maintenance/scripts/claude-attribution-audit.sh
skills/fleet-maintenance/scripts/agent-cli-audit.sh
skills/fleet-maintenance/scripts/octopool-audit.sh
skills/fleet-maintenance/scripts/op-profile-audit.sh
```

Collector snapshots are observed evidence, not configuration. Store reviewed snapshots under `~/Projects/manager/fleet/snapshots/<host-id>.json`. `diff` reports source-only candidates; Peter chooses which enter `full`.

## Safety contract

- Read `~/Projects/manager/computers.yaml`; use live Tailscale state and deduplicate hosts by hardware UUID. Exclude handed-off and unknown machines.
- Audit hosts in parallel; mutate one host at a time. Recheck agent activity immediately before every repo or Xcode mutation.
- Skip repositories with a user process cwd inside them or a Git lock. Recent files are audit signal, not a blocker. Permit dirty worktrees only through the conflict-free fast-forward procedure below.
- Homebrew and global npm updates are allowed while agents/services are running. This can mix old in-memory code with replaced files, break later imports or child processes, and let Homebrew terminate/reopen cask GUI apps. Accept that package-update risk; never manually terminate or restart services. Verify health and report interruptions or pending restarts.
- Never reset, clean, stash, rebase, switch branches, delete local work, push, install macOS updates, or reboot during routine maintenance.
- Snapshot role-critical services before package updates. Do not restart OpenClaw gateways or other services unless explicitly authorized; verify them afterward using their owning skill.
- Keep a per-host action log. An unreachable host is pending, never current.

## Run order

1. Resolve the host's `full` or `worker` profile, collect observed inventory, and run package-ownership preflight.
2. Sync eligible repos using the existing Git/toolchain.
3. Update Homebrew and global npm packages on every eligible, reachable host regardless of active agents/services.
4. Verify each host's macOS stable/beta track.
5. Sync Xcode through `$xcode-sync`.
6. Empty Trash only when explicitly requested for this run; perform approved package cleanup.
7. Re-audit disk, tools, package ownership, repos, memory, and role-critical services.

## Preflight

Record hostname, hardware UUID, macOS, architecture, uptime, Tailscale state, selected Xcode, free bytes/percent, Trash size, Homebrew prefix/version, Node/npm versions, running Brew services, active coding-agent processes, and resident-memory outliers:

```bash
node skills/fleet-maintenance/scripts/fleet-profile.mjs collect
skills/fleet-maintenance/scripts/host-health-audit.sh 30
ssh -o RequestTTY=no -o RemoteCommand=none HOST 'node --input-type=module - collect' \
  < skills/fleet-maintenance/scripts/fleet-profile.mjs
ssh -o RequestTTY=no -o RemoteCommand=none HOST 'bash -s -- 30' \
  < skills/fleet-maintenance/scripts/host-health-audit.sh
```

Report every process above 30 GiB resident memory. Do not alert on virtual size alone, sum related processes, or terminate a process automatically. Record PID, resident GiB, user, executable, role, and whether memory remains above the threshold on a second sample.

Classify startup-disk space using both absolute and relative capacity:

- healthy: at least 100 GiB and 15% free
- warning: 50–100 GiB or 10–15% free
- critical: below 50 GiB or 10% free

Do not start Xcode expansion on warning/critical space. Never delete outside Trash, superseded package-manager artifacts, or Xcode paths governed by `$xcode-sync` without explicit approval.

## Repository sync

Run the read-only candidate audit on each host:

```bash
skills/fleet-maintenance/scripts/repo-sync-audit.sh ~/Projects 3
ssh -o RequestTTY=no -o RemoteCommand=none HOST 'bash -s -- "$HOME/Projects" 3' \
  < skills/fleet-maintenance/scripts/repo-sync-audit.sh
```

Apply the audited policy with the bundled updater. It rechecks safety, fetches noninteractively, fast-forwards clean or conflict-free dirty worktrees, and isolates refusals:

```bash
skills/fleet-maintenance/scripts/repo-sync-update.sh ~/Projects 3
ssh -o RequestTTY=no -o RemoteCommand=none HOST \
  '"$HOME/Projects/agent-scripts/skills/fleet-maintenance/scripts/repo-sync-update.sh" "$HOME/Projects" 3'
```

Only process rows marked `candidate`. Recheck branch, upstream, Git locks, and active process cwd immediately before mutation, then:

```bash
git -C "$repo" fetch --prune
git -C "$repo" rev-list --left-right --count HEAD...@{upstream}
```

Run fetches noninteractively and bound each one (for example five minutes). On timeout, authentication failure, or network failure, terminate that fetch, mark the repo pending, and continue. Never let one stale/private mirror stall the host, rewrite its remote, or prompt for credentials during fleet maintenance.

Interpret counts as `ahead behind`:

- `0 0`: current; no action.
- `0 N`: inspect `git log --oneline HEAD..@{upstream}` and `git diff --stat HEAD..@{upstream}`. Record `HEAD` and worktree status. Run `git merge --ff-only --no-autostash --no-overwrite-ignore @{upstream}`. A clean worktree should advance. A dirty worktree may advance only when Git can preserve every local change without overlap; Git refusal means `skip-local-overlap`, not an error to repair. After success, require no unmerged entries, the expected upstream commit at `HEAD`, and all prior local modifications still present. After refusal, require unchanged `HEAD`, no unmerged entries, and unchanged worktree status.
- `N 0` or `N M`: inspect local commit subjects/authors and `git diff --stat @{upstream}...HEAD`; explain likely intent and escalate. Never push or rewrite.
- detached/no upstream/fetch failure: understand remotes, branches, recent commits, and worktree state; escalate with the smallest useful decision.

Do not infer that a stale local checkout should match a sibling checkout. Each visible checkout is user-managed.

Never use `pull` or `merge` as a conflict resolver. Never pass `--autostash`, create a stash, discard changes, or stage files. A non-fast-forward, checkout-overwrite warning, merge conflict, or changed safety snapshot stops that repository only; continue the fleet pass.

## Homebrew

Skip only if Homebrew is absent. Running agents/services do not block package mutation:

First render the host's resolved profile to a temporary Brewfile and run `brew bundle check --verbose --file FILE`. Review missing entries. `brew bundle install --file FILE` may install or upgrade declared dependencies. Never run `brew bundle cleanup --force`; extras are allowed under the default `minimum` policy. Remove an entry only through an explicitly approved prune action.

Homebrew 6 can refuse third-party formulae until they are trusted. If that happens, verify each formula is already declared in the resolved fleet profile, then grant trust to those exact formula names with `brew trust --formula ...`. Never trust an entire tap or a formula discovered only from the remote tap. Record the resulting trust list with `brew trust --json v1` and resume the same generated Brewfile.

```bash
brew update
brew outdated --json=v2
brew upgrade
brew services list
brew doctor
```

Treat `brew doctor` as advisory; do not blindly apply its suggestions. Compare services before/after. Use `brew cleanup --prune=30` after successful verification; use more aggressive cleanup only for disk pressure and explicit approval.

If an upgrade replaces Node, Git, Codex, or another executable used by an active agent/service, accept that later imports or child processes may observe new files and report the risk. Allow Homebrew's controlled quit/reopen for cask GUI apps, including possible session termination; do not manually restart services, change taps, or uninstall packages automatically.

## Package ownership

Run `scripts/host-health-audit.sh` before and after package mutations. Investigate its ownership candidates plus duplicate launchd labels/listeners, executable version skew, and collisions across Homebrew formulae/casks, global npm, standalone apps, and app-bundled CLIs.

For each candidate, resolve executable realpaths, package receipts, service definitions, listeners, running processes, dependents, versions, and intended host role. Prefer one canonical owner. Disable or uninstall a redundant owner only when its replacement is healthy, no installed package depends on it, and the current request authorizes the fix. Never infer a conflict from a shared name alone; formula/app pairs can be intentional.

## Global npm packages

“Update npm” means registry-backed, top-level global packages—not project dependencies. Never change a repository's `package.json` or lockfile here.

1. Record `node --version`, `npm --version`, `npm prefix -g`, and `npm ls -g --depth=0 --json`.
2. Run `npm outdated -g --depth=0 --json`; its nonzero exit can mean updates exist.
3. Update each registry package to `name@latest`. Skip linked, file, Git, bundled, and ambiguous packages; report them.
4. Let the owner update npm itself: Homebrew updates a Homebrew Node/npm; only use `npm install -g npm@latest` for a self-managed npm installation. Verify the resulting `npm --version`.
5. Re-run inventory and smoke-test the updated global CLIs. Use `$npm` and `$one-password` only if a private package actually requires registry authentication; never expose npm credentials.

Major global-package updates are intended even when the package currently backs an active coding agent or service. Accept the risk of mixed old/new files; do not restart the process. Smoke-test the newly installed CLI separately and report failures or pending restarts.

## macOS track

Record `sw_vers` product/build and current beta-seed enrollment. Resolve the latest stable and current beta build from authoritative current Apple sources; do not hardcode versions or infer track from version number alone. Use `softwareupdate --list` to confirm what the host is actually offered on its configured track.

Classify each Mac as current, update available, track ambiguous, unsupported, or unreachable. Preserve its configured stable/beta track. Routine maintenance does not switch tracks, install macOS updates, or reboot: prepare the exact update and request a maintenance window after confirming no active agents/services and adequate backup/disk state.

## Xcode

Invoke `$xcode-sync`; do not duplicate its install logic. Resolve current stable/beta/RC versions from an authoritative current source, not hardcoded versions. Preserve each host's selected stable or prerelease track while maintaining the canonical stable/prerelease slots and previous-major retention policy defined there.

Verify product build, signature, first-launch state, selection, host compatibility, and free space. Report unsupported and unreachable Macs separately.

Simulator hygiene is a required fleet invariant, not optional disk cleanup. Run the `$xcode-sync` simulator-hygiene audit on every reachable Mac. A host without Xcode/`simctl` is `not-applicable`; a host with Xcode is current only when Apple reports no outdated or unusable runtime images and no devices tied to unavailable runtimes. Repair only after checking for active Xcode work; the canonical action refuses while simulator devices are booted.

## Trash and disk

Measure Trash on every run. Keep it read-only unless the current request explicitly says to clear/empty Trash. With that consent, empty only the current user's home-volume Trash after resolving and verifying the path:

```bash
trash="$HOME/.Trash"
home_real=$(cd "$HOME" && pwd -P)
trash_real=$(cd "$trash" && pwd -P)
if [[ "$trash_real" != "$home_real/.Trash" ]]; then
  printf 'refusing unexpected Trash path: %s\n' "$trash_real" >&2
  exit 2
fi
find "$trash_real" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
```

Never empty another user's Trash or Trash on external volumes. Recheck disk capacity afterward; escalate unexplained growth instead of broad cache deletion.

## Baseline health checks

Include these read-only checks in the report; mutations need separate authority:

- available macOS/security updates and whether a reboot is recommended
- Mac App Store application drift via `mas outdated`, when `mas` is installed
- last successful Time Machine backup, when configured
- SMART/storage warnings and APFS volume health signals available from `diskutil`
- uptime, clock synchronization, and laptop battery health/cycle count
- Tailscale reachability/version drift
- failed Brew services and role-specific LaunchAgents/daemons
- FileVault, firewall, Gatekeeper, and SIP status drift
- Developer ID certificate and important SSH credential expiry dates, never secret values

Useful optional maintenance: stale package caches/logs, abandoned containers/VMs, old device-support files not managed by CoreSimulator, orphaned launch agents, and large Downloads. Audit first; delete only with explicit scope.

## Finish

Return a host matrix with: reachability, agent CLI install/auth/live-test state, Octopool shim/login/pool-health state, agent skill-link state, global Git-ignore state, active/deferred reason, disk before/after, Trash reclaimed, Brew/npm changes, repos pulled/current/skipped/escalated, Xcode stable/prerelease build and selected track, backup/update/service warnings, and remaining user decisions.
