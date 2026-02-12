---
summary: 'Multi-agent system directives and coordination rules. Master reference for agent behavior.'
read_when:
  - Coordinating subagents or running tmux-based agent sessions.
---

# Claude Subagent Quickstart

## CLI Basics
- Launch long-running subagents inside tmux so the session can persist. Example:

  ```bash
  tmux new-session -d -s claude-haiku 'claude --model haiku'
  tmux attach -t claude-haiku
  ```

  Once inside the session, run `/model` to confirm the active alias (`haiku` maps to Claude 3.5 Haiku) and switch models if needed.
- Need to queue instructions without attaching? Use `tmux send-keys -t <session> "your command" Enter` to inject text into a running agent session.
- Always switch to the fast Haiku model upfront (`claude --model haiku --dangerously-skip-permissions …` or `/model haiku` in-session) to keep turnaround fast.
- Two modes:
  - **One-shot tasks** (single summary, short answer): run `claude --model haiku --dangerously-skip-permissions --print …` in a tmux session, wait with `sleep 30`, then read the output buffer.
  - **Interactive tasks** (multi-file edits, iterative prompts): start `claude --model haiku --dangerously-skip-permissions` in tmux, send prompts with `tmux send-keys`, and capture completed responses with `tmux capture-pane`. Expect to sleep between turns so Haiku can finish before you scrape the pane.
## One-Shot Prompts
- The CLI accepts the prompt as a trailing argument in one-shot mode. Multi-line prompts can be piped: `echo "..." | claude --print`.
- Add `--output-format json` when you need structured fields (e.g., summary + bullets) for post-processing.
- Keep prompts explicit about reading full files: "Read docs/example.md in full and produce a 2-3 sentence summary covering all sections."

## Bulk Markdown Conversion
- Produce the markdown inventory first (`pnpm run docs:list`) and feed batches of filenames to your Claude session.
- For each batch, issue a single instruction like "Rewrite these files with YAML front matter summaries, keep all other content verbatim." Haiku can loop over multi-file edits when you provide the explicit list.
- After Claude reports success, diff each file locally (`git diff docs/<file>.md`) before moving to the next batch.

## Supervisor Loop Pattern
- A supervisor loop can spin up tmux sessions, auto-wake workers, and call Claude via `claude --dangerously-skip-permissions "<prompt>"` to keep tmux automation flowing.
- Supervisor responses typically end with tokens like `CONTINUE`, `SEND: <message>`, or `RESTART` so the orchestrator can decide the next action.
- Progress can be tracked in a local file (e.g., `.ralph/progress.md`) by default.
- Send ad-hoc instructions to a worker session with `tmux send-keys -t <worker-session> "your guidance" Enter`.
