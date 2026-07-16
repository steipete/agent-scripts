---
name: npm
description: "npm registry ops: login, whoami, names, publish; 1Password tmux."
metadata: {"clawdbot":{"emoji":"📦","requires":{"bins":["npm","node","tmux","op","jq"]}}}
---

# npm

Use for npm registry/account tasks: `npm whoami`, package availability, package reservation, publish, org checks, and auth debugging.

## Auth

- Use `one-password` first for secret rules.
- Never run `op` directly in the shell tool.
- Primary item: `npm Registry - steipete - Release Automation` in `Molty`.
- Default to `OP_SERVICE_ACCOUNT_TOKEN`; no desktop unlock. The item carries the working registry session (`registry_token`) plus username/password/TOTP fallback.
- Desktop `npmjs` fallback is explicit only: pass `--account my.1password.com` when Molty is unavailable and the user wants the fallback. Explicit `release`/`publish` requests are consent for its unlock prompt.
- Stop and ask if the item is missing, the account/vault is ambiguous, credentials are malformed, npm denies package access, or the requested package/version does not match the repo release target.
- Run npm auth work inside one task window of the shared `op-work` tmux session (`clawdbot-op.sock`; see `one-password`). Reuse the window on failure; kill it when the npm task is done. Never mint an npm-specific socket or session.
- Keep npm auth in a temp npmrc; delete it after the command.
- All helpers share `scripts/npm-auth.sh`: stored `registry_token` session first, then `scripts/npm-auth-login.mjs` registry login with a fresh six-digit OTP; successful fallback sessions are cached back to the same item. Do not hand-roll field extraction, registry login, or cache writes.
- Credential selection prefers canonical field `id`, then `purpose`, then a unique label; duplicate label-only matches are rejected (legacy `npmjs` may retain same-label fields).
- For ad-hoc authenticated registry commands, use `scripts/npm-service.sh -- <npm args...>`; use `publish-package.sh` for a local package.
- npm 11 prompt piping is brittle; avoid `printf ... | npm login --auth-type=legacy`.
- Avoid `expect` for npm login unless necessary; logs can echo prompts and are easy to get wrong.
- Prefer the helper's registry API login path (`npm-profile` `loginCouch`) for automation.
- If auth shape is ambiguous or `npm whoami` fails, stop and ask for the exact field label / credential fix. Do not probe more 1Password items or open another tmux window/session.

## Package Publishing

From the package root, inside the same auth tmux window:

```bash
/Users/steipete/Projects/agent-scripts/skills/npm/scripts/publish-package.sh
```

The helper verifies identity, refuses an existing package version, publishes with a fresh OTP, retries one expired OTP, verifies registry visibility, and cleans auth files.

## Package Reservation

Use `scripts/reserve-packages.sh` from inside the same tmux window:

```bash
/Users/steipete/Projects/agent-scripts/skills/npm/scripts/reserve-packages.sh package-one package-two
```

What it does:
- reads the Molty release-automation item once via `op`
- reuses the stored registry session or creates one from username/password/TOTP
- publishes `0.0.0` placeholder packages with a generic README
- continues after per-package publish failures
- redacts tokens/OTP in logs
- cleans temp npmrc/work dirs

Notes:
- npm may reject names as too similar to already-published names. Treat that as a registry policy result, not an auth failure.
- npm CLI prompt piping is brittle on npm 11. Prefer the helper’s registry API login path over scripted `npm login`.
- For scoped packages, `npm view` can lag/404 even when the package exists. Check `npm access get status <pkg>`; `public` or a publish failure saying `previously published versions` means the name is reserved.
