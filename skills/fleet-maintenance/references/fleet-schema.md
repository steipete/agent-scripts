# Fleet inventory schema

The mutable desired-state inventory lives at `~/Projects/manager/fleet/inventory.json`. Keep it outside the skill so skill distribution cannot overwrite host data.

## Top level

- `version`: schema version.
- `profiles`: exactly `full` and `worker` unless Peter explicitly changes the model.
- `hosts`: canonical computer ID to profile and local-account references.

`computers.yaml` remains the source for identity, SSH topology, role notes, reachability hints, and handed-off exclusions. The fleet inventory owns desired software and credential references.

## Profiles

- `package_policy: minimum`: require declared packages but tolerate extras.
- `source_of_truth_host`: optional host used for reviewed comparison, never automatic adoption.
- `bootstrap_observed_host` and `bootstrap_observed_at`: provenance for the initial managed list; they do not replace reviewed source-host comparison.
- `adoption_policy`: `reviewed` or `explicit`; neither permits silent capture.
- `managed.homebrew`: `taps`, top-level `formulae`, and `casks`.
- `managed.mas`: objects with numeric `id` and human-readable `name`.
- `managed.npm`: top-level global package names.
- `managed.apps`: manual applications, preferably with `bundle_id` and `name`. These are report-only until an explicit installer is defined.
- `managed.tools`: required command names, including tools such as the stable-path 1Password CLI that are intentionally not Homebrew-managed. These are presence checks only.
- `requirements.filevault` and `requirements.git_signing`: non-package configuration checks. Report drift; do not mutate security or signing configuration during ordinary package apply.
- `requirements.agent_skill_links`: require the MacBook-style agent skill mirror on both profiles.
- `requirements.git_global_ignore`: exact patterns required in `~/.config/git/ignore` on both profiles. The fleet action also pins `core.excludesFile` to that canonical path; alternate configured files require manual review before repair.
- `requirements.claude_attribution`: `none` requires `~/.claude/settings.json` to set empty commit and pull-request attribution plus `sessionUrl: false`. This user setting applies to Claude Code and Claude Desktop coding sessions. The repair action preserves unrelated settings and fails closed on malformed, linked, or non-object configuration.
- `requirements.agent_clis`: `authenticated` requires both the official Codex and Claude Code CLIs to resolve, report versions, and pass their non-interactive authentication checks. Both profiles manage the `codex` and `claude-code` casks; Claude Desktop's separate `claude` cask does not satisfy this requirement. `scripts/agent-cli-audit.sh --live` adds bounded, tool-free, non-persistent model-turn proof. Claude OAuth is host-local and must never be copied between Macs.
- `requirements.github_cache`: must be `"octopool"` on both profiles. Installing the Octopool package does not satisfy this requirement by itself. `scripts/octopool-audit.sh` verifies the binary, both non-interactive and login zsh `gh` resolution, complete `whoami --json` client metadata, and an all-healthy nonempty identity pool. `scripts/octopool-audit.sh --repair` uses the existing authenticated real GitHub CLI at a stable path, logs in to `https://octopool.openclaw.ai`, installs the zsh shim, and adds a guarded managed `.zprofile` block only when macOS login startup ordering bypasses the otherwise-working shim.
- `requirements.op_cli_integrity`: require a native-architecture, Apple Developer ID-validated, single-link regular file at `~/bin/op` from AgileBits, with both it and `~/bin` current-user-owned, ACL-free, and not group/world writable, plus `/opt/homebrew/bin/op -> ~/bin/op`. This requirement applies to every host and is not waived by a service-account exception.
- `requirements.op_service_account_profile`: require a single-link, current-user-owned, mode-0600, ACL-free `~/.config/op/molty-service-account-token` beneath canonical non-symlink home/config ancestors; one file-backed Codex-managed loader block in `~/.profile`; and a secure `~/.zprofile` that either sources `.profile` or loads its service-account export. The token value never belongs in inventory or Git.
- `requirements.window_title_icons`: `true` requires the per-user accessibility preference `com.apple.universalaccess showWindowTitlebarIcons` to read as `1`. A missing or unset value is drift and is repairable; unexpected preference read failures remain fatal. Audit it with `~/Projects/manager/scripts/window-title-icons-audit.sh`; repair writes the boolean preference, verifies it, and restarts Finder only when it changed and Finder was already running for the current user.
- `requirements.xcode_simulator_hygiene`: `no-outdated` requires the `$xcode-sync` audit on every reachable Mac. Hosts without Xcode/`simctl` satisfy the policy as `not-applicable`; Xcode hosts must have no Apple-classified outdated or unusable runtime images and no devices tied to unavailable runtimes.
- `hosts.<id>.requirement_exceptions`: narrowly exempt a host from named profile requirements when a documented security boundary makes the shared desired state unsafe. This does not exempt the host from `managed.tools` or `op_cli_integrity`; for example, `clawmac` still requires the verified `op` CLI but not the personal service-account token until its device class and authorization are verified.

## Agent skill mirror

Every fleet Mac must have:

- `~/.codex/skills/agent-scripts -> ~/Projects/agent-scripts/skills`
- `~/.codex/skills/manager -> ~/Projects/manager/skills`
- a real `~/.claude/skills` directory containing flat per-skill links, with agent-scripts winning name collisions; locally owned real skill directories and valid Codex backlinks to them are preserved
- `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, and `~/.claude/AGENTS.md` pointing to `~/Projects/agent-scripts/AGENTS.MD`

Run `scripts/agent-skill-links-audit.sh` read-only. Run it with `--repair` to invoke the canonical idempotent `~/Projects/agent-scripts/scripts/sync-skills` for broad mirror, pruning, and instruction-pointer work. Sync preserves every real destination, treats the same directory identity as satisfied local ownership, and fails on other real destination conflicts.

The audit also reports `reason=nested-self-link` for same-name symlinks inside real top-level Claude directories that resolve back to their parent. This bounded read-only check is not an exhaustive graph validator. For this topology, call the reviewed sync owner directly by absolute path with `--repair-nested-self-links [--dry-run] -- NAME...`; the audit has no scoped repair wrapper or owner override. The owner requires a nonempty, unique safe-basename allowlist, accessible real registration roots, a real Claude skill directory with `SKILL.md`, and exact literal Codex/nested targets with matching directory identities. It validates the entire batch before unlinking only nested leaves and exits before ordinary sync. Already-absent leaves are no-ops only with valid surrounding topology. Revalidation catches drift but is not atomic against concurrent writers; later failures report partial progress without rollback. Real directories, contents, valid backlinks, unrelated entries, and shared instruction pointers remain untouched by scoped repair.

Homebrew dependencies do not belong in `formulae`; declare intentionally installed leaves. Homebrew is rolling-release state, not a version lock.

## Hosts and accounts

Each host selects one profile. Use `aliases` only for common spoken names. Keep any `requirement_exceptions` minimal and explain the security boundary in the fleet setup document.

Each account entry contains:

- `username`
- `roles`: any of `login`, `admin`, and `filevault-unlock`
- `onepassword_item_id`: opaque 1Password item ID, never a secret value
- `credential_status`: `pending`, `stored`, or `verified`

Use one unique 1Password Login item per host/account. Keep FileVault recovery material in a separate concealed field or linked recovery item. Never place passwords, recovery keys, private keys, or `op://` resolved values in this repository.

## Observed snapshots

Write live collector output to `~/Projects/manager/fleet/snapshots/<host-id>.json`. A snapshot is evidence, not desired state. Never adopt source-only packages automatically; show a diff and let Peter select what becomes managed.

Required-tool entries normally record executable presence. The CamSnap entry additionally records `version` from `camsnap --version` and the resolved executable's SHA-256 so a rollout can prove the selected binary, including a reviewed host-local override, rather than merely proving that a path exists.
