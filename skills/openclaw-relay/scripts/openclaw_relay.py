#!/usr/bin/env python3
"""Relay prompts or posts through local or remote OpenClaw sessions."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent

DEFAULT_TRANSPORT = os.environ.get("OPENCLAW_RELAY_TRANSPORT", "local")
DEFAULT_HOST = os.environ.get("OPENCLAW_RELAY_HOST", "steipete@steipete-macstudio.local")
DEFAULT_CWD = os.environ.get("OPENCLAW_RELAY_CWD")
DEFAULT_ACPX_REPO = os.environ.get("OPENCLAW_RELAY_ACPX_REPO")
DEFAULT_SESSION = os.environ.get("OPENCLAW_RELAY_SESSION", "codex-bridge")
DEFAULT_AGENT = os.environ.get("OPENCLAW_RELAY_ACPX_AGENT", "openclaw")
DEFAULT_MAIN_SESSION = os.environ.get("OPENCLAW_RELAY_MAIN_SESSION", "agent:<agentId>:main")
DEFAULT_GATEWAY_URL = os.environ.get("OPENCLAW_RELAY_GATEWAY_URL", "ws://127.0.0.1:18789")
DEFAULT_GATEWAY_TOKEN_FILE = os.environ.get("OPENCLAW_RELAY_GATEWAY_TOKEN_FILE")
DEFAULT_TARGETS_FILE = os.environ.get(
    "OPENCLAW_RELAY_TARGETS_FILE",
    str(SKILL_DIR / "config" / "session_aliases.json"),
)

_REMOTE_HOME_CACHE: dict[str, str] = {}


class RelayError(RuntimeError):
    pass


def print_json(data: object) -> None:
    json.dump(data, sys.stdout, indent=2)
    sys.stdout.write("\n")


def run_local(
    argv: list[str],
    *,
    cwd: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(argv, text=True, capture_output=True, check=False, cwd=cwd)
    if check and proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip() or f"command failed: {proc.returncode}"
        raise RelayError(message)
    return proc


def run_ssh(host: str, command: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        [
            "ssh",
            "-o",
            "RequestTTY=no",
            "-o",
            "RemoteCommand=none",
            host,
            f"bash -lc {shlex.quote(command)}",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if check and proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip() or f"ssh failed: {proc.returncode}"
        raise RelayError(message)
    return proc


def remote_home(host: str) -> str:
    cached = _REMOTE_HOME_CACHE.get(host)
    if cached:
        return cached
    proc = run_ssh(host, 'printf "%s" "$HOME"')
    home = proc.stdout.strip()
    if not home:
        raise RelayError(f"could not resolve remote home for {host}")
    _REMOTE_HOME_CACHE[host] = home
    return home


def normalize_args(args: argparse.Namespace) -> argparse.Namespace:
    if args.transport == "local":
        cwd = args.cwd or DEFAULT_CWD or os.getcwd()
        if not args.cwd and not DEFAULT_CWD and not (Path(cwd) / "scripts" / "run-node.mjs").exists():
            for candidate in (Path.home() / "clawdbot", Path.home() / "Projects" / "clawdbot"):
                if (candidate / "scripts" / "run-node.mjs").exists():
                    cwd = str(candidate)
                    break
        gateway_token_file = args.gateway_token_file or DEFAULT_GATEWAY_TOKEN_FILE
        args.cwd = str(Path(cwd).expanduser())
        acpx_repo = args.acpx_repo or DEFAULT_ACPX_REPO
        if not acpx_repo:
            oss_acpx = Path.home() / "Projects" / "oss" / "acpx"
            acpx_repo = str(oss_acpx if oss_acpx.exists() else Path(args.cwd) / "extensions" / "acpx")
        args.acpx_repo = str(Path(acpx_repo).expanduser())
        args.gateway_token_file = str(Path(gateway_token_file).expanduser()) if gateway_token_file else None
        return args

    home = remote_home(args.host)
    args.cwd = args.cwd or DEFAULT_CWD or f"{home}/clawdbot"
    args.acpx_repo = args.acpx_repo or DEFAULT_ACPX_REPO or f"{home}/Projects/oss/acpx"
    args.gateway_token_file = (
        args.gateway_token_file
        or DEFAULT_GATEWAY_TOKEN_FILE
        or f"{home}/.openclaw/gateway.token"
    )
    return args


def local_acpx_argv(acpx_repo: str, argv: list[str]) -> tuple[list[str], str]:
    repo = Path(acpx_repo).expanduser()
    dist_cli = repo / "dist" / "cli.js"
    if dist_cli.exists():
        return (["node", str(dist_cli), *argv], str(repo))
    return (["pnpm", "exec", "tsx", "src/cli.ts", *argv], str(repo))


def run_acpx(
    args: argparse.Namespace,
    argv: list[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    if args.transport == "local":
        command, cwd = local_acpx_argv(args.acpx_repo, argv)
        return run_local(command, cwd=cwd, check=check)
    parts = " ".join(shlex.quote(part) for part in argv)
    command = (
        f"cd {shlex.quote(args.acpx_repo)} && "
        "runner() { "
        'if [ -x dist/cli.js ]; then node dist/cli.js "$@"; '
        'else pnpm exec tsx src/cli.ts "$@"; fi; }; '
        f"runner {parts}"
    )
    return run_ssh(args.host, command, check=check)


def run_openclaw(
    args: argparse.Namespace,
    argv: list[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    if args.transport == "local":
        return run_local(["node", "scripts/run-node.mjs", *argv], cwd=args.cwd, check=check)
    parts = " ".join(shlex.quote(part) for part in argv)
    command = f"cd {shlex.quote(args.cwd)} && node scripts/run-node.mjs {parts}"
    return run_ssh(args.host, command, check=check)


def parse_json_line(line: str) -> Any | None:
    text = line.strip()
    if not text.startswith("{"):
        return None
    return json.loads(text)


def parse_json_lines(text: str) -> list[Any]:
    items: list[Any] = []
    for line in text.splitlines():
        parsed = parse_json_line(line)
        if parsed is not None:
            items.append(parsed)
    return items


def require_single_json(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped:
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError:
            payload = None
        if isinstance(payload, dict):
            return payload
    items = parse_json_lines(text)
    if not items:
        raise RelayError(f"no JSON payload found in output:\n{text.strip()}")
    payload = items[-1]
    if not isinstance(payload, dict):
        raise RelayError(f"unexpected JSON payload: {payload!r}")
    return payload


def maybe_parse_embedded_json(text: str) -> dict[str, Any] | None:
    stripped = text.strip()
    candidates = [stripped]
    if "{" in stripped and "}" in stripped:
        start = stripped.find("{")
        end = stripped.rfind("}") + 1
        if start >= 0 and end > start:
            candidates.append(stripped[start:end])
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def extract_block_text(block: Any) -> str:
    if not isinstance(block, dict):
        return ""
    if "Text" in block and isinstance(block["Text"], str):
        return block["Text"]
    if "Thinking" in block and isinstance(block["Thinking"], dict):
        return str(block["Thinking"].get("text") or "")
    if "ToolUse" in block and isinstance(block["ToolUse"], dict):
        name = str(block["ToolUse"].get("name") or "tool")
        return f"[tool:{name}]"
    return ""


def simplify_message(entry: Any) -> dict[str, Any] | None:
    if not isinstance(entry, dict):
        return None
    if "User" in entry and isinstance(entry["User"], dict):
        user = entry["User"]
        text = "\n".join(
            part for part in (extract_block_text(block) for block in user.get("content") or []) if part
        ).strip()
        return {"role": "user", "id": user.get("id"), "text": text}
    if "Agent" in entry and isinstance(entry["Agent"], dict):
        agent = entry["Agent"]
        text = "\n".join(
            part for part in (extract_block_text(block) for block in agent.get("content") or []) if part
        ).strip()
        return {"role": "assistant", "text": text}
    return None


def trimmed_session(payload: dict[str, Any], limit: int) -> dict[str, Any]:
    messages = payload.get("messages")
    simplified = []
    if isinstance(messages, list):
        for item in messages[-max(limit, 0) :]:
            simplified_item = simplify_message(item)
            if simplified_item is not None:
                simplified.append(simplified_item)
    last_assistant = next(
        (item["text"] for item in reversed(simplified) if item.get("role") == "assistant" and item.get("text")),
        "",
    )
    return {
        "acpxRecordId": payload.get("acpxRecordId"),
        "acpxSessionId": payload.get("acpSessionId"),
        "name": payload.get("name"),
        "cwd": payload.get("cwd"),
        "updatedAt": payload.get("updated_at"),
        "lastSeq": payload.get("lastSeq"),
        "lastPromptAt": payload.get("lastPromptAt"),
        "pid": payload.get("pid"),
        "closed": payload.get("closed"),
        "messageCount": len(messages) if isinstance(messages, list) else 0,
        "lastAssistantText": last_assistant,
        "messages": simplified,
    }


def ensure_session(args: argparse.Namespace) -> dict[str, Any]:
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "sessions",
            "ensure",
            "--name",
            args.session,
        ],
    )
    return require_single_json(proc.stdout)


def fetch_session(args: argparse.Namespace) -> dict[str, Any]:
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "sessions",
            "show",
            args.session,
        ],
    )
    return require_single_json(proc.stdout)


def list_sessions_payload(args: argparse.Namespace) -> dict[str, Any]:
    proc = run_openclaw(args, ["sessions", "--json"])
    return require_single_json(proc.stdout)


def load_aliases(path: str) -> dict[str, str]:
    file_path = Path(path).expanduser()
    if not file_path.exists():
        return {}
    data = json.loads(file_path.read_text())
    if not isinstance(data, dict):
        raise RelayError(f"target aliases file must contain an object: {file_path}")
    aliases: dict[str, str] = {}
    for raw_key, raw_value in data.items():
        if isinstance(raw_key, str) and isinstance(raw_value, str):
            aliases[raw_key.strip()] = raw_value.strip()
    return aliases


def simplify_session_row(entry: dict[str, Any]) -> dict[str, Any]:
    return {
        "key": entry.get("key"),
        "label": entry.get("label"),
        "sessionId": entry.get("sessionId"),
        "kind": entry.get("kind"),
        "agentId": entry.get("agentId"),
        "updatedAt": entry.get("updatedAt"),
        "lastChannel": entry.get("lastChannel"),
        "lastTo": entry.get("lastTo"),
        "deliveryContext": entry.get("deliveryContext"),
    }


def match_session_rows(rows: list[dict[str, Any]], target: str) -> list[dict[str, Any]]:
    normalized = target.strip().lower()
    matches: list[dict[str, Any]] = []
    for row in rows:
        key = str(row.get("key") or "").strip()
        label = str(row.get("label") or "").strip()
        if key and key.lower() == normalized:
            matches.append(row)
            continue
        if label and label.lower() == normalized:
            matches.append(row)
            continue
        if key and key.lower().endswith(f":{normalized}"):
            matches.append(row)
    return matches


def resolve_target(args: argparse.Namespace, target: str) -> dict[str, Any]:
    aliases = load_aliases(args.targets_file)
    alias_key = target.strip()
    if alias_key in aliases:
        return {
            "input": target,
            "alias": alias_key,
            "sessionKey": aliases[alias_key],
        }
    if target.startswith("agent:"):
        return {
            "input": target,
            "alias": None,
            "sessionKey": target.strip(),
        }
    payload = list_sessions_payload(args)
    rows = [row for row in payload.get("sessions", []) if isinstance(row, dict)]
    matches = match_session_rows(rows, target)
    if not matches:
        raise RelayError(f"unknown target: {target}")
    if len(matches) > 1:
        raise RelayError(
            f"ambiguous target {target!r}: " + ", ".join(str(row.get("key") or "?") for row in matches[:5])
        )
    row = matches[0]
    return {
        "input": target,
        "alias": None,
        "sessionKey": row.get("key"),
        "label": row.get("label"),
        "sessionId": row.get("sessionId"),
        "kind": row.get("kind"),
    }


def build_openclaw_agent_command(args: argparse.Namespace, session_key: str) -> str:
    runner = shlex.quote(f"{args.cwd}/scripts/run-node.mjs")
    token_file_arg = (
        f" --token-file {shlex.quote(args.gateway_token_file)}" if args.gateway_token_file else ""
    )
    return (
        "env OPENCLAW_HIDE_BANNER=1 OPENCLAW_SUPPRESS_NOTES=1 "
        f"node {runner} acp "
        f"--url {shlex.quote(args.gateway_url)} "
        f"{token_file_arg} "
        f"--session {shlex.quote(session_key)}"
    )


def run_target_exec(args: argparse.Namespace, session_key: str, message: str) -> dict[str, Any]:
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            "--agent",
            build_openclaw_agent_command(args, session_key),
            "exec",
            message,
        ],
    )
    frames = parse_json_lines(proc.stdout)
    return extract_prompt_result(frames)


def extract_prompt_result(payloads: list[Any]) -> dict[str, Any]:
    chunks: list[str] = []
    stop_reason = None
    for payload in payloads:
        if not isinstance(payload, dict):
            continue
        method = payload.get("method")
        if method == "session/update":
            params = payload.get("params")
            if not isinstance(params, dict):
                continue
            update = params.get("update")
            if not isinstance(update, dict):
                continue
            if update.get("sessionUpdate") != "agent_message_chunk":
                continue
            content = update.get("content")
            if isinstance(content, dict) and content.get("type") == "text":
                text = str(content.get("text") or "")
                if text:
                    chunks.append(text)
        if "result" in payload and isinstance(payload["result"], dict):
            stop_reason = payload["result"].get("stopReason", stop_reason)
    return {
        "assistantText": "".join(chunks).strip(),
        "stopReason": stop_reason,
        "frames": payloads,
    }


def derive_delivery_from_key(session_key: str) -> dict[str, Any]:
    raw_parts = [part for part in session_key.split(":") if part]
    parts = raw_parts[2:] if len(raw_parts) >= 3 and raw_parts[0] == "agent" else raw_parts
    if len(parts) < 3:
        raise RelayError(f"cannot derive delivery target from session key: {session_key}")
    channel = parts[0].strip().lower()
    kind = parts[1].strip().lower()
    rest = ":".join(parts[2:]).strip()
    if not channel or not kind or not rest:
        raise RelayError(f"cannot derive delivery target from session key: {session_key}")
    match = re.search(r":(?:topic|thread):(\d+)$", rest)
    thread_id = match.group(1) if match else None
    peer = re.sub(r":(?:topic|thread):\d+$", "", rest).strip()
    if kind == "channel":
        target = f"channel:{peer}"
    elif kind == "group":
        target = f"channel:{peer}" if channel in {"discord", "slack"} else f"group:{peer}"
    elif kind in {"direct", "dm"}:
        if channel in {"discord", "slack"} and not peer.startswith("user:"):
            target = f"user:{peer}"
        else:
            target = peer
    else:
        raise RelayError(f"unsupported delivery kind {kind!r} for session key: {session_key}")
    return {
        "channel": channel,
        "to": target,
        "threadId": thread_id,
    }


def build_publish_prompt(target_key: str, text: str, context: str | None) -> str:
    context_line = f"Context: {context.strip()}" if context and context.strip() else None
    lines = [
        "Use sessions_send once.",
        f"Target session key: {target_key}",
        "Message for the target session:",
        *([context_line] if context_line else []),
        "If the text fits the target session context, announce exactly this text.",
        'If it does not fit, reply exactly "ANNOUNCE_SKIP".',
        f"Text: {text}",
        'After the tool call, reply with JSON only: {"delivery":"posted|skipped|unknown","targetSession":"...","note":"..."}',
        'Treat ANNOUNCE_SKIP or NO_REPLY as "skipped".',
    ]
    return "\n".join(lines)


def read_text_arg(args: argparse.Namespace) -> str:
    if args.text is not None:
        return args.text
    text_file = getattr(args, "text_file", None)
    if not text_file:
        return ""
    if text_file == "-":
        return sys.stdin.read()
    try:
        return Path(text_file).expanduser().read_text(encoding="utf-8")
    except OSError as error:
        raise RelayError(f"could not read --text-file {text_file!r}: {error}") from error


def cmd_doctor(args: argparse.Namespace) -> None:
    if args.transport == "local":
        acpx_repo = Path(args.acpx_repo)
        token_file = args.gateway_token_file
        token_ready = bool(token_file) and Path(token_file).is_file()
        ready = acpx_repo.is_dir() and Path(args.cwd, ".acpxrc.json").is_file() and token_ready
        version_proc = run_acpx(args, ["--version"], check=False)
        status_proc = run_acpx(
            args,
            [
                "--cwd",
                args.cwd,
                "--format",
                "json",
                "--json-strict",
                args.agent,
                "status",
                "--session",
                args.session,
            ],
            check=False,
        )
    else:
        probe = run_ssh(
            args.host,
            " && ".join(
                [
                    f"test -d {shlex.quote(args.acpx_repo)}",
                    f"test -f {shlex.quote(args.cwd)}/.acpxrc.json",
                    f"test -s {shlex.quote(args.gateway_token_file)}",
                ]
            ),
            check=False,
        )
        ready = probe.returncode == 0
        version_proc = run_acpx(args, ["--version"], check=False)
        status_proc = run_acpx(
            args,
            [
                "--cwd",
                args.cwd,
                "--format",
                "json",
                "--json-strict",
                args.agent,
                "status",
                "--session",
                args.session,
            ],
            check=False,
        )
    visibility_proc = run_openclaw(args, ["config", "get", "tools.sessions.visibility"], check=False)
    visibility = visibility_proc.stdout.strip()
    if visibility_proc.returncode != 0 or not visibility:
        visibility = "tree (default/unset)"
    payload = {
        "transport": args.transport,
        "host": args.host if args.transport == "ssh" else None,
        "acpxRepo": args.acpx_repo,
        "cwd": args.cwd,
        "controlSession": args.session,
        "mainSession": args.main_session,
        "ready": ready and version_proc.returncode == 0,
        "version": version_proc.stdout.strip(),
        "targetsFile": args.targets_file,
        "knownTargets": load_aliases(args.targets_file),
        "sessionsVisibility": visibility,
        "status": require_single_json(status_proc.stdout) if status_proc.stdout.strip() else None,
    }
    print_json(payload)


def cmd_targets(args: argparse.Namespace) -> None:
    print_json(load_aliases(args.targets_file))


def cmd_resolve(args: argparse.Namespace) -> None:
    print_json(resolve_target(args, args.target))


def cmd_sessions(args: argparse.Namespace) -> None:
    payload = list_sessions_payload(args)
    rows = [row for row in payload.get("sessions", []) if isinstance(row, dict)]
    query = (args.query or "").strip().lower()
    if query:
        rows = [
            row
            for row in rows
            if query in str(row.get("key") or "").lower()
            or query in str(row.get("label") or "").lower()
            or query in str(row.get("kind") or "").lower()
        ]
    print_json({"count": len(rows), "sessions": [simplify_session_row(row) for row in rows[: max(args.limit, 0)]]})


def cmd_ensure(args: argparse.Namespace) -> None:
    ensured = ensure_session(args)
    current = trimmed_session(fetch_session(args), args.limit)
    print_json({"ensure": ensured, "session": current})


def cmd_send(args: argparse.Namespace) -> None:
    ensured = ensure_session(args)
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "prompt",
            "--session",
            args.session,
            args.message,
        ],
    )
    frames = parse_json_lines(proc.stdout)
    result = extract_prompt_result(frames)
    current = trimmed_session(fetch_session(args), args.limit)
    print_json({"ensure": ensured, **result, "session": current})


def cmd_ask(args: argparse.Namespace) -> None:
    target = resolve_target(args, args.target)
    result = run_target_exec(args, str(target["sessionKey"]), args.message)
    print_json({"target": target, **result})


def cmd_publish(args: argparse.Namespace) -> None:
    target = resolve_target(args, args.target)
    prompt = build_publish_prompt(str(target["sessionKey"]), read_text_arg(args), args.context)
    if args.dry_run:
        print_json({"target": target, "prompt": prompt})
        return
    ensured = ensure_session(args)
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "prompt",
            "--session",
            args.session,
            prompt,
        ],
    )
    frames = parse_json_lines(proc.stdout)
    result = extract_prompt_result(frames)
    report = maybe_parse_embedded_json(result.get("assistantText") or "")
    current = trimmed_session(fetch_session(args), args.limit)
    print_json({"ensure": ensured, "target": target, **result, "report": report, "session": current})


def cmd_force_send(args: argparse.Namespace) -> None:
    text = read_text_arg(args).strip()
    media = (args.media or "").strip()
    if not text and not media:
        raise RelayError("force-send needs --text, --media, or both")
    target = resolve_target(args, args.target)
    delivery = {
        **derive_delivery_from_key(str(target["sessionKey"])),
        **({"channel": args.channel} if args.channel else {}),
        **({"to": args.to} if args.to else {}),
        **({"threadId": args.thread_id} if args.thread_id else {}),
        **({"accountId": args.account_id} if args.account_id else {}),
    }
    if not delivery.get("channel") or not delivery.get("to"):
        raise RelayError("force-send needs a deliverable target; pass --channel and --to to override")
    argv = [
        "message",
        "send",
        "--channel",
        str(delivery["channel"]),
        "--target",
        str(delivery["to"]),
        "--json",
    ]
    if text:
        argv.extend(["--message", text])
    if media:
        argv.extend(["--media", media])
    if delivery.get("accountId"):
        argv.extend(["--account", str(delivery["accountId"])])
    if delivery.get("threadId"):
        argv.extend(["--thread-id", str(delivery["threadId"])])
    if args.force_document:
        argv.append("--force-document")
    if args.gif_playback:
        argv.append("--gif-playback")
    if args.silent:
        argv.append("--silent")
    if args.dry_run:
        print_json({"target": target, "delivery": delivery, "argv": argv})
        return
    proc = run_openclaw(args, argv)
    print_json({"target": target, "delivery": delivery, "result": require_single_json(proc.stdout)})


def cmd_start(args: argparse.Namespace) -> None:
    ensured = ensure_session(args)
    before = fetch_session(args)
    queued = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "prompt",
            "--session",
            args.session,
            "--no-wait",
            args.message,
        ],
    )
    payload = require_single_json(queued.stdout)
    print_json(
        {
            "ensure": ensured,
            "queued": payload,
            "waitFromLastSeq": before.get("lastSeq", 0),
            "waitFromUpdatedAt": before.get("updated_at"),
        }
    )


def cmd_status(args: argparse.Namespace) -> None:
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "status",
            "--session",
            args.session,
        ],
    )
    print_json({"status": require_single_json(proc.stdout), "session": trimmed_session(fetch_session(args), args.limit)})


def cmd_show(args: argparse.Namespace) -> None:
    print_json(trimmed_session(fetch_session(args), args.limit))


def cmd_wait(args: argparse.Namespace) -> None:
    deadline = time.time() + args.timeout
    baseline_seq = args.after_seq
    baseline_updated = args.after_updated_at
    while True:
        payload = fetch_session(args)
        last_seq = int(payload.get("lastSeq") or 0)
        updated_at = str(payload.get("updated_at") or "")
        if baseline_seq is None and baseline_updated is None:
            print_json(trimmed_session(payload, args.limit))
            return
        if baseline_seq is not None and last_seq > baseline_seq:
            print_json(trimmed_session(payload, args.limit))
            return
        if baseline_updated is not None and updated_at and updated_at != baseline_updated:
            print_json(trimmed_session(payload, args.limit))
            return
        if time.time() >= deadline:
            raise RelayError("wait timed out")
        time.sleep(args.interval)


def cmd_cancel(args: argparse.Namespace) -> None:
    proc = run_acpx(
        args,
        [
            "--cwd",
            args.cwd,
            "--format",
            "json",
            "--json-strict",
            args.agent,
            "cancel",
            "--session",
            args.session,
        ],
    )
    print_json(require_single_json(proc.stdout))


def add_shared_flags(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--transport", choices=("local", "ssh"), default=DEFAULT_TRANSPORT)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--acpx-repo")
    parser.add_argument("--cwd")
    parser.add_argument("--agent", default=DEFAULT_AGENT)
    parser.add_argument("--session", default=DEFAULT_SESSION)
    parser.add_argument("--main-session", default=DEFAULT_MAIN_SESSION)
    parser.add_argument("--gateway-url", default=DEFAULT_GATEWAY_URL)
    parser.add_argument("--gateway-token-file")
    parser.add_argument("--targets-file", default=DEFAULT_TARGETS_FILE)
    parser.add_argument("--limit", type=int, default=6)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor")
    add_shared_flags(doctor)
    doctor.set_defaults(func=cmd_doctor)

    targets = subparsers.add_parser("targets")
    add_shared_flags(targets)
    targets.set_defaults(func=cmd_targets)

    resolve = subparsers.add_parser("resolve")
    add_shared_flags(resolve)
    resolve.add_argument("--target", required=True)
    resolve.set_defaults(func=cmd_resolve)

    sessions = subparsers.add_parser("sessions")
    add_shared_flags(sessions)
    sessions.add_argument("--query")
    sessions.set_defaults(func=cmd_sessions)

    ensure = subparsers.add_parser("ensure")
    add_shared_flags(ensure)
    ensure.set_defaults(func=cmd_ensure)

    send = subparsers.add_parser("send")
    add_shared_flags(send)
    send.add_argument("--message", required=True)
    send.set_defaults(func=cmd_send)

    ask = subparsers.add_parser("ask")
    add_shared_flags(ask)
    ask.add_argument("--target", required=True)
    ask.add_argument("--message", required=True)
    ask.set_defaults(func=cmd_ask)

    publish = subparsers.add_parser("publish")
    add_shared_flags(publish)
    publish.add_argument("--target", required=True)
    publish_text = publish.add_mutually_exclusive_group(required=True)
    publish_text.add_argument("--text")
    publish_text.add_argument("--text-file", help="Read announcement text from a UTF-8 file, or '-' for stdin")
    publish.add_argument("--context")
    publish.add_argument("--dry-run", action="store_true")
    publish.set_defaults(func=cmd_publish)

    force_send = subparsers.add_parser("force-send")
    add_shared_flags(force_send)
    force_send.add_argument("--target", required=True)
    force_text = force_send.add_mutually_exclusive_group()
    force_text.add_argument("--text")
    force_text.add_argument("--text-file", help="Read message text from a UTF-8 file, or '-' for stdin")
    force_send.add_argument("--media", help="Attach media path or URL when the channel supports it")
    force_send.add_argument("--channel")
    force_send.add_argument("--to")
    force_send.add_argument("--account-id")
    force_send.add_argument("--thread-id")
    force_send.add_argument("--force-document", action="store_true")
    force_send.add_argument("--gif-playback", action="store_true")
    force_send.add_argument("--silent", action="store_true")
    force_send.add_argument("--dry-run", action="store_true")
    force_send.set_defaults(func=cmd_force_send)

    start = subparsers.add_parser("start")
    add_shared_flags(start)
    start.add_argument("--message", required=True)
    start.set_defaults(func=cmd_start)

    status = subparsers.add_parser("status")
    add_shared_flags(status)
    status.set_defaults(func=cmd_status)

    show = subparsers.add_parser("show")
    add_shared_flags(show)
    show.set_defaults(func=cmd_show)

    wait = subparsers.add_parser("wait")
    add_shared_flags(wait)
    wait.add_argument("--after-seq", type=int)
    wait.add_argument("--after-updated-at")
    wait.add_argument("--timeout", type=float, default=30.0)
    wait.add_argument("--interval", type=float, default=1.0)
    wait.set_defaults(func=cmd_wait)

    cancel = subparsers.add_parser("cancel")
    add_shared_flags(cancel)
    cancel.set_defaults(func=cmd_cancel)

    return parser


def main() -> int:
    parser = build_parser()
    args = normalize_args(parser.parse_args())
    try:
        args.func(args)
    except RelayError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
