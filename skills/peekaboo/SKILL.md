---
name: peekaboo
description: "macOS screenshots, UI inspect, clicks, typing, app/window automation."
---

# Peekaboo

Use for macOS screen capture, UI inspection, and GUI automation.

## Binary

- Prefer `~/bin/peekaboo` when present; it is Peter's local release copy.
- Else use `peekaboo`.
- Check first: `~/bin/peekaboo --version || peekaboo --version`.

## Mac app host

- Launch `Peekaboo.app` before live capture/automation; the CLI does not auto-launch it.
- The app owns TCC grants and serves `~/Library/Application Support/Peekaboo/bridge.sock`.
- Installed app: `open -a Peekaboo`. Repo build: build the `Apps/Mac/Peekaboo.xcodeproj` `Peekaboo` scheme, then open the resulting `Peekaboo.app`.
- `peekaboo daemon start` is not an app launch; the daemon has separate permissions and `daemon.sock`.
- Verify `peekaboo bridge status --verbose --json --bridge-socket "$HOME/Library/Application Support/Peekaboo/bridge.sock"` selects `hostKind: gui`.

## Safety

- Check permissions before capture/automation: `peekaboo permissions status --json`.
- Screenshot needs Screen Recording; clicks/typing/window control need Accessibility.
- On remote Macs, Screenshot may be blocked by missing Screen Recording while
  clicks/typing still work through Accessibility; continue with clicks or DOM
  automation when the target is otherwise knowable.
- Prefer `--json` for machine parsing and `--no-remote` when testing local TCC.
- Do not click/type/destructively automate unless user asked or target is a controlled test.

## Common Commands

```bash
PB="${PEEKABOO_BIN:-$HOME/bin/peekaboo}"
[ -x "$PB" ] || PB="$(command -v peekaboo)"

open -a Peekaboo
"$PB" bridge status --verbose --json --bridge-socket "$HOME/Library/Application Support/Peekaboo/bridge.sock"
"$PB" permissions status --json
"$PB" list screens --json
"$PB" list apps --json
"$PB" list windows --app Safari --json
"$PB" image --mode screen --screen-index 0 --path /tmp/screen.png --json --no-remote
"$PB" see --app frontmost --path /tmp/frontmost.png --json --annotate
"$PB" tools --json
"$PB" learn
"$PB" click --coords 100,100 --json
"$PB" type "text" --json
```

## Workflow

1. Resolve `PB` as above and confirm version when install state matters.
2. For live UI work, launch `Peekaboo.app`; verify the GUI bridge and its permissions.
3. Run `permissions status --json`; if missing TCC, report exact missing grant.
4. For screenshots, use `image`; include `--path`, `--json`, and usually `--no-remote` only when deliberately testing caller-local TCC.
5. For element targeting, run `see --json --annotate`, then click by element id/snapshot.
6. For long-running/change-aware screen capture, use `capture live`; for video frame sampling, use `capture video`.
7. Use `tools --json` for command/tool discovery and `learn` when the full agent guide is useful.
8. Verify output files with `sips -g pixelWidth -g pixelHeight <path>` or view the image.

Docs: `~/Projects/Peekaboo/docs/commands/`.
