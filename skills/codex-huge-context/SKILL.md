---
name: codex-huge-context
description: "Codex 1M context: direct OpenAI Responses API inference, safe Astra/Sol/Terra/Luna input headroom, Keychain delivery, and Mac fleet rollout."
---

# Codex Huge Context

Use this skill when configuring, repairing, or auditing Codex's one-million-token context setup. The intended topology is a direct API inference route that preserves the normal ChatGPT login for Gmail, Calendar, and other connector OAuth:

```text
Codex inference -> Keychain auth helper -> https://api.openai.com/v1/responses
Codex connectors -> normal ChatGPT login in auth.json
```

This is not an HTTP proxy. The API remains authoritative for access, actual model limits, and billing.

## Atomic provider and context invariant

Treat the provider selector, context window, compaction threshold, and custom model catalogue as one atomic configuration. In Peter's normal ChatGPT-authenticated setup, `model_provider = "openai"` selects the ChatGPT-backed route; never attach this skill's direct-API `922000` context window and `700000` compaction threshold to that route. The provider identifier alone does not determine transport: built-in `openai` with API-key authentication can also use the API. This skill and its preflight require the named `openai_api_direct` provider below so inference uses its dedicated Keychain helper while connector login stays separate.

That split configuration can leave a 700,000-token compaction threshold attached to a smaller provider or model-metadata limit. Codex may also clamp the requested window, so root numbers alone do not prove the usable context. A browser- or Computer Use-heavy thread can grow past the provider's real limit before compaction, receive `context_length_exceeded`, and become unable to compact because the compaction request itself no longer fits. Verify the fresh session's reported effective window as well as the files on disk.

The required preflight treats this mismatch as fatal. Do not launch or resume Codex after any config writer, app settings change, model change, or fleet sync until the preflight passes. If it reports an unsafe split configuration, restore `model_provider = "openai_api_direct"`, restart every Codex desktop/shared app server, and start or fork a fresh thread. Resuming the failed thread preserves its recorded provider.

## Safe input window

[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) exposes a 1,050,000-token total context window and can produce up to 128,000 output tokens. Codex does not set a smaller output budget on normal Responses API turns, so the catalogue must describe the safe input allowance rather than the raw total:

```text
1,050,000 total - 128,000 maximum output = 922,000 safe input
```

Use the same safe input policy for both direct-provider catalogue models ([GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) has the same 1,050,000-token window and 128,000-token output limit):

- `gpt-6-astra`
- `gpt-6.1-sol`

[GPT-6.2 Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol) is not a catalogue model yet: it is API-only (the ChatGPT route returns 400 `model_not_found`), and Codex 0.164.0 has no metadata for it to copy (`Model metadata for gpt-6.2-sol not found`), so its launches (`-m gpt-6.2-sol -c 'model_provider="openai_api_direct"'`) use Codex's fallback metadata and the base 500k window. Do not invent a catalogue entry or a 6.2 profile; add both once Codex ships genuine 6.2 metadata.

Preserve the operator's selected supported model when configuring context. The examples below use Astra; enabling large context does not authorize replacing another selected model.

Codex applies its normal 95% effective-window reserve to the 922,000-token input allowance, so it reports and guards about 875,900 usable tokens. Set automatic compaction to 700,000 total active tokens. That leaves about 175,900 tokens inside Codex's effective guard and 222,000 tokens before the provider's safe input ceiling for the next prompt, tool schemas and results, instructions, serialization overhead, and compaction itself. This larger margin is intentional: Codex 0.144.6 checks already-recorded context before adding the next user message and context updates, and a terminal response that crosses the threshold may not compact until the following turn. The observed large-context workload grew by about 144,000 tokens in one turn, which made the former 820,000 threshold too aggressive.

Long-context requests above 272,000 input tokens use the provider's higher long-context pricing. Do not enable this route accidentally for workloads that do not benefit from it.

## Required files

`~/.codex/models-api-1m.json` must contain these values for all five model slugs while preserving the rest of each model entry:

```json
{
  "context_window": 922000,
  "max_context_window": 922000,
  "auto_compact_token_limit": 700000
}
```

Leave `effective_context_window_percent` absent to use Codex's 95% default, or set it explicitly to the integer `95`. Null, floating-point, or other values are invalid.

Start from the complete native catalogue for the installed Codex release, including its reviewer models: a custom catalogue replaces the built-in catalogue rather than overlaying selected entries. Use every model's genuine metadata and a client satisfying its minimum version. Preserve instructions, tool capabilities, and every safety field, including required review behavior; override only the context and compaction fields above. Never invent Astra metadata or relabel a Sol entry as Astra. The API context contract above supports the direct-provider override; it does not expand ChatGPT entitlement or relax client safety requirements. The preflight validates context and credential delivery, not the provenance of the remaining catalogue metadata.

The catalogue describes each model's safe maximum. Sessions default to a 500,000-token window
(Peter, 2026-10-12): step latency roughly doubles from 100k to 300k of context, so lanes run
smaller unless they need more. The root section of `~/.codex/config.toml` needs:

```toml
model = "gpt-6.1-sol"
model_provider = "openai_api_direct"
model_context_window = 500000
model_auto_compact_token_limit = 400000
model_auto_compact_token_limit_scope = "total"
model_catalog_json = "/Users/steipete/.codex/models-api-1m.json"

[model_providers.openai_api_direct]
name = "OpenAI API direct"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = true

[model_providers.openai_api_direct.auth]
command = "/Users/steipete/.codex/bin/fetch-openai-inference-key.zsh"
timeout_ms = 5000
refresh_interval_ms = 300000
```

`supports_websockets = true` is required: custom providers default to HTTP, which re-uploads the full
prompt every step (measured 2026-10-12 at 150k context on a ~22 Mbps uplink: 26-59 s per step on HTTP vs
0.8-3.7 s on WebSocket, whose continuations send only new items).

Replace legacy values such as `model_context_window = 1050000` or `922000` at the root; do not leave duplicate root keys. Keep the scope at `total`, because the safety budget applies to the complete active request, not only content added after a compaction prefix.

### Profiles

Codex 0.162 profiles are files: `codex -p <name>` layers `~/.codex/<name>.config.toml` over the
base config (names allow only letters, digits, `_` and `-`). Every host carries four:

| Profile | `model` | Context |
|---|---|---|
| `astra` | `gpt-6-astra` | base 500k |
| `sol61` | `gpt-6.1-sol` | base 500k |
| `astra-1m` | `gpt-6-astra` | `922000` window, `700000` compaction, scope `total` |
| `sol61-1m` | `gpt-6.1-sol` | `922000` window, `700000` compaction, scope `total` |

Each profile also sets `model_provider = "openai_api_direct"`. Any profile that sets context keys
must pin that provider and use 500000/400000 or 922000/700000; the preflight enforces this for
every `*.config.toml`. Use a `-1m` profile only for work that needs a whole-repo context.

Before modifying a host, back up both config files to date-stamped sibling files. Do not replace unrelated project, plugin, MCP, notification, approval, model-selection, or reasoning settings.

## API credential delivery

The auth command reads a dedicated Keychain delivery copy, never a value in TOML or an environment variable:

```zsh
#!/bin/zsh
set -euo pipefail
exec /usr/bin/security find-generic-password \
  -a Codex \
  -s "Codex OpenAI inference API" \
  -w /Users/steipete/Library/Keychains/login.keychain-db
```

Resolve and verify the host's actual Keychain path at installation time; the example is host-specific. Keep that absolute, non-secret path inside the external executable, not `$HOME`/`~`, a provider override, or non-empty `auth.args`. Managed autoreview replaces the client's HOME/USERPROFILE and XDG config/data/state/cache directories. Implicit Keychain selection can then return exit 44 (`SecKeychainSearchCopyNext` item not found) even though parent-session delivery succeeds. Repair the wrapper's Keychain selection—not the reviewer's HOME, filesystem grants, or credential access. Inspect an existing helper before changing it; it may already use explicit selection.

Use `$one-password` before handling the API key. The canonical value is the `OPENAI_API_KEY` field in Molty's `AI API Key - OpenAI - OPENAI_API_KEY - Serviceable Access` item. Read it through the service-account workflow inside the shared `op-work` tmux session and store/update only the Keychain copy. Never print, copy over SSH, place in a profile, or write it to a temporary file.

The Keychain item should allow `/usr/bin/security`. A Keychain read normally produces no prompt. A login Keychain locked after reboot, or a command launched via noninteractive SSH, can fail with error 36 (`User interaction is not allowed`). Do not work around that failure with a plaintext file or a long-lived secret daemon: unlock the host from its local graphical session, install the item there, then use Codex from that local session.

Before the first fresh or resumed Codex launch on a configured machine, run the secret-safe preflight. It validates the direct-provider config, safe input and compaction values, all five catalogue entries, helper executable, and non-empty helper delivery without printing the credential or helper stderr:

```zsh
ruby ~/.codex/skills/agent-scripts/codex-huge-context/scripts/preflight.rb
```

Do not mark a rollout complete or launch Codex when this fails. With `requires_openai_auth = false`, a missing Keychain delivery copy cannot fall back to the normal Codex login: the direct provider can reach `api.openai.com/v1/responses` without a bearer header and surface an opaque HTTP 401 instead. The preflight fails earlier with the bootstrap action needed. An unset `GITHUB_PAT_TOKEN` warning is independent and non-blocking for inference; it explains a concurrent GitHub MCP startup failure but must not be confused with OpenAI API authentication.

The preflight's provider check is not cosmetic. A machine with the direct provider table and million-token catalogue present but root `model_provider = "openai"` is broken, even when every numeric value is otherwise correct.

### Managed autoreview delivery

Before an isolated review using this named route, also check the external helper with private home directories:

```bash
ruby ~/.codex/skills/agent-scripts/codex-huge-context/scripts/preflight.rb --private-home
```

This opt-in diagnostic validates the parent context first, then invokes the same trusted helper with fresh HOME/USERPROFILE and XDG config/data/state/cache directories. It captures and discards helper output in memory; it never copies credentials into files or environment variables. Other environment and working-directory settings remain inherited. This is not the complete sanitized reviewer environment, a sandbox test, or inference proof.

Finish with an actual `$autoreview` run on the intended frozen Git target using `--codex-config 'model_provider="openai_api_direct"'` and the intended model unchanged. Preserve source scanning, auth projection, sandboxing, and all tool credential denials. Only the client-side auth command may read the existing Keychain delivery item; never test by asking reviewer tools to retrieve real credentials. If explicit selection still fails, report the exact secret-safe status and stop—no provider fallback, real-HOME propagation, secret file/env handoff, credential broker, or sandbox exception.

## ChatGPT connector login

`requires_openai_auth = false` applies only to the custom inference provider. The root Codex login must remain ChatGPT-authenticated for ChatGPT-connected plugins to work:

```zsh
codex login status
```

If it reports API-key login and the host needs Gmail, Calendar, or similar connectors, use `codex logout` followed by `codex login` from the local user session. Do not copy `auth.json` or OAuth tokens between Macs.

## Fresh, resumed, and shared-server sessions

`-m gpt-6-astra` selects a model, not a provider. Fresh sessions read the root `model_provider`; session metadata then records the chosen provider. `codex exec resume` does not reuse it: on codex-cli 0.164.0 it runs on the provider in force at resume time, root config or `-c model_provider=…` (verified 2026-11-23), so pass the provider on every exec resume.

Codex TUI sessions can reuse `~/.codex/app-server-control/app-server-control.sock`. A shared app server retains the configuration it loaded at startup, so changing files on disk does not update sessions attached to an older server. After changing context or authentication configuration:

1. let active turns finish;
2. restart the Codex desktop app and any shared CLI app server;
3. start a fresh session for final proof;
4. resume old sessions only when preserving their recorded model/provider is intentional.

A same-value CLI override such as `codex -c 'model_provider="openai_api_direct"'` forces an embedded per-invocation app server and is useful for diagnosis without changing the provider or service tier, but it is not the fleet rollout's permanent fix.

## Fleet rollout

Use `$fleet-maintenance` and `$remote-mac` first. Read `~/Projects/manager/computers.yaml`, use live Tailscale state, deduplicate by hardware UUID, and exclude handed-off hosts. Audit all reachable hosts before mutation; mutate one host at a time.

Peter's current personal Mac scope is MacBook Pro; the London and two San Francisco Mac Studios; the separately owned SF Mac Mini (`mac-mini-sf` / `steipete-mini-sf`); ClawMac; FoundationClaw; MegaClaw; and MiniClaw. FoundationClaw's provider account and Mac14,12 hardware identity are verified, but its previously working credential needs a provider reset before Tailscale enrollment, canonical checkouts, and remaining worker bootstrap can continue; the SF Mac Mini's trusted SSH/account path is pending; MiniClaw's canonical Tailscale identity is `miniclaw`. Verify each host identity and the `agent-scripts` checkout before changing any remote files. Keep a per-host result with:

- config and catalogue backups;
- root safe input, compaction threshold, and scope;
- all five catalogue entries and their context values;
- preflight result in the intended local user session;
- `codex login status`, without showing any credential;
- direct API probe result;
- shared app-server version and whether a restart remains pending.

The `agent-scripts` skill checkout is normally exposed by `~/.codex/skills/agent-scripts`. After pushing this skill, fast-forward only eligible `~/Projects/agent-scripts` checkouts. Never reset, stash, overwrite an active or dirty checkout, or interrupt an active Codex turn merely to reload configuration; report it as pending instead.

## Verification

Run these in the intended local user session:

```zsh
ruby ~/.codex/skills/agent-scripts/codex-huge-context/scripts/preflight.rb
codex login status
jq -r '.models[] | select(.slug == "gpt-6-astra" or .slug == "gpt-6.1-sol") | [.slug, .context_window, .max_context_window, .auto_compact_token_limit] | @tsv' ~/.codex/models-api-1m.json
codex exec --skip-git-repo-check 'Reply with exactly: direct-api-safe-context-ok' </dev/null
```

Then probe each profile (`codex exec --skip-git-repo-check -p <name> ...`) and read
`model_context_window` from the fresh rollout's `task_started` event: 475000 for the base,
`astra` and `sol61`; 875900 for `astra-1m` and `sol61-1m`.

Expect a successful preflight, `922000`, `922000`, and `700000` for every catalogue model, ChatGPT login for connector-capable hosts, and the exact probe response. A successful direct API probe does not prove connector OAuth; confirm `codex login status` separately.

For final TUI proof, send the prompt text and Enter as separate terminal actions. Do not treat echoed input as the model's response.

## Failure policy

- Preflight reports an unsafe split configuration: restore this skill's `openai_api_direct` provider contract; do not lower the direct-route threshold or leave the 922K/700K overrides attached to Peter's ChatGPT-backed `openai` route. Restart all app servers and use a fresh or forked thread because existing session metadata preserves the old provider.
- API response still clamps or rejects a request: record the server response; do not claim a client catalogue override changed server entitlement.
- Context overflow below 700,000 active tokens: preserve the session file and inspect the last token-accounting events before lowering the threshold further.
- Context overflow above 700,000 without compaction: verify the running app-server version and loaded configuration; an old server can retain the previous threshold.
- HTTP 401 `Missing bearer or basic authentication in header`: rerun the preflight and repair Keychain delivery; do not switch providers or ordinary Codex authentication.
- Keychain error 36 remotely: leave the safe configuration staged and require a local GUI unlock. Never weaken secret storage.
- Root API-key login but connectors are required: ask the local user to complete the ChatGPT login; inference can remain on the direct provider.
- Existing `openai_api_direct` provider differs from this contract: inspect it before changing it; do not append a duplicate TOML table.
