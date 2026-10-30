# Launch details

Read for Ultrafast/interactive launches, catalog checks, or a missing CLI. The [entrypoint](../SKILL.md) owns the gate and default launch flags.

### Optional Ultrafast

Fast (`service_tier="fast"`, sent as API `priority`) is the default tier
(Peter, 2026-10-30). When the user asks for Ultrafast, replace
`-c 'service_tier="fast"'` with `-c 'service_tier="ultrafast"'` and add
`-c 'model_auto_compact_token_limit=260000'` in the fresh/resume recipes. Keep
6.1 Sol, high reasoning, `--enable fast_mode`, and the existing provider and
execution policy. Do not promote either tier into the base `config.toml`; the
launch flags own the tier.

For an interactive session, use the same per-launch flags:

```bash
codex --no-daemon -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"'
```

An optional `ultrafast.config.toml` profile in `CODEX_HOME` may instead contain
the model, high reasoning, and Ultrafast tier; select it with
`codex --no-daemon -p ultrafast`. It must preserve the configured provider and
context settings. Prefer these launch overrides to `/ultrafast` or `/fast`: the
slash commands save the selected tier into the base config.

For Ultrafast, the active model catalog must list `gpt-6.1-sol` with the `ultrafast` tier, and
the account must support it. The installed Codex's native catalog lists 6.1 Sol
with `priority` only, and Codex can silently omit an unlisted tier, so the
custom direct-API catalog (`$codex-huge-context`) carries the ultrafast entry.
Verify the actual API response tier (`service_tier` in the response) before
calling a run Ultrafast; verified 2026-10-10 on the direct API route. After an
approved custom-catalog refresh, `--no-daemon` loads it in a fresh process. See
the official
[configuration reference](https://developers.openai.com/codex/config-reference/),
[GPT-6.1 Sol model page](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
and [Ultrafast API guide](https://developers.openai.com/api/docs/guides/ultrafast-mode).

## Prompt-file launch example

Prompt via temp file, never inline quoting:

```bash
P=$(mktemp); cat >"$P" <<'EOF'
<goal, repo + key paths, constraints ("don't touch X"), non-goals, proof expected, output shape>
EOF
command codex exec --yolo -C <repo> \
  -m gpt-6.1-sol -c 'model_reasoning_effort="high"' \
  --enable fast_mode -c 'service_tier="fast"' \
  -o /tmp/codex-last.md - <"$P" 2>/dev/null
```
## CLI installation

- `command codex` bypasses any interactive shell alias. If codex isn't on PATH, it depends on how it was installed:
  - node/standalone install: `fnm exec --using default -- codex`
  - ChatGPT desktop app: the CLI ships bundled at `/Applications/ChatGPT.app/Contents/Resources/codex`. Expose **that** binary with an **exec-wrapper, not a symlink**. Ensure `~/.local/bin` stays on PATH (for zsh, persist the export in `~/.zshrc`), then:
    ```sh
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    if [ -e "$HOME/.local/bin/codex" ] || [ -L "$HOME/.local/bin/codex" ]; then
      printf '%s\n' 'codex launcher already exists; leaving it unchanged' >&2
    else
      printf '#!/bin/sh\nexec "/Applications/ChatGPT.app/Contents/Resources/codex" "$@"\n' > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"
    fi
    ```
    Or install the self-contained CLI via `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, which needs no wrapper.

## Host and execution details

- Host preflight: run `timeout 8 git --version`; if it hangs on a Mac with Xcode-beta selected, export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in the session and every work order.

If the saved configuration selects the `openai_api_direct` route, run `$codex-huge-context`'s `scripts/preflight.rb` (via `ruby`) before the first fresh or resumed launch in the batch. Fail closed if it cannot deliver the Keychain credential; never work around it by overriding the provider or using ordinary Codex authentication.

- These overrides select the model and service tier, not the provider. Resumed sessions retain their recorded provider; use a fresh worker if it is incompatible with 6.1 Sol. Do not silently fall back to another model.
- `--yolo` is the house default; Codex may run commands/tests freely. Keep prompts scoped to the target repo.
- If `--yolo` is unavailable—either the CLI rejects the flag or the selected model/backend rejects unrestricted execution—replace it with `--approve-for-me` and retry once. Never pass both. Preserve every other argument and constraint.
- Prompt via temp file, never inline quoting; read the `-o` result, not the JSONL stream.
- Suppress stderr (`2>/dev/null`); drop suppression only to debug a failing run.
- Long runs: Bash run_in_background; read `-o` on exit. Don't kill quiet runs <30 min.
