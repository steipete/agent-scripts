---
name: nano-banana-pro
description: "Nano Banana/Gemini image gen/edit: text/image input, 512-4K workflows."
---

# Nano Banana Image Generation & Editing

Generate new images or edit existing ones with Google's Gemini image models: Nano Banana 2 (Gemini 3.1 Flash Image, the default) or Nano Banana Pro (Gemini 3 Pro Image, `--model pro`).

## Usage

Run the script by absolute path from the user's working directory (do NOT cd to the skill directory first). `$SKILL_DIR` below is the directory containing this SKILL.md, i.e. the skill's base directory as your agent reports it (for example `~/.claude/skills/nano-banana-pro` for Claude Code, `~/.codex/skills/agent-scripts/nano-banana-pro` for Codex).

**Generate new image:**
```bash
uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "your image description" --filename "output-name.png" [--resolution 512|1K|2K|4K] [--model flash|pro|MODEL_ID] [--api-key KEY]
```

**Edit existing image:**
```bash
uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "editing instructions" --filename "output-name.png" --input-image "path/to/input.png" [--resolution 512|1K|2K|4K] [--model flash|pro|MODEL_ID] [--api-key KEY]
```

**Important:** Always run from the user's current working directory so images are saved where the user is working, not in the skill directory.

## Default Workflow (draft → iterate → final)

Goal: fast iteration without burning time on 4K until the prompt is correct.

- Draft (1K): quick feedback loop
  - `uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "<draft prompt>" --filename "yyyy-mm-dd-hh-mm-ss-draft.png" --resolution 1K`
- Iterate: adjust prompt in small diffs; keep filename new per run
  - If editing: keep the same `--input-image` for every iteration until you’re happy.
- Final (4K): only when prompt is locked
  - `uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "<final prompt>" --filename "yyyy-mm-dd-hh-mm-ss-final.png" --resolution 4K`

## Model Selection

- `flash` (default) → `gemini-3.1-flash-image` (Nano Banana 2): fast and cheap; the right choice for drafts, generation, and simple edits.
- `pro` → `gemini-3-pro-image` (Nano Banana Pro): 1K/2K/4K only, slower and costs more per image, but noticeably better at photoreal edits of real photos, such as inserting furniture or products into a room or patio while keeping perspective, lighting, and shadows believable. Use it for those edits, or when the user asks for Pro.
- Any other value is passed through as a Gemini model id (for example `gemini-2.5-flash-image`).

Precedence: `--model`, then the `NANO_BANANA_MODEL` environment variable, then `flash`. Use GA ids: `-preview` ids exist only on the `v1beta` API and return 404 on the `v1` API that current `google-genai` uses by default.

## Resolution Options

The Gemini image API supports these output size values:

- **512** - compact ~512px-class resolution (Flash only; Pro returns 400 `Image size 512 is not supported for this model`)
- **1K** (default) - ~1024px resolution
- **2K** - ~2048px resolution
- **4K** - ~4096px resolution

When editing without an explicit `--resolution`, the script picks 1K, 2K, or 4K from the input image's longest side.

Map user requests to API parameters:
- "512", "512px", "0.5K", "thumbnail", "tiny" → `512`
- No mention of resolution → `1K`
- "low resolution", "1080", "1080p", "1K" → `1K`
- "2K", "2048", "normal", "medium resolution" → `2K`
- "high resolution", "high-res", "hi-res", "4K", "ultra" → `4K`

## API Key

The script checks for API key in this order:
1. `--api-key` argument (use if user provided key in chat)
2. `GEMINI_API_KEY` environment variable

If neither is available, the script exits with an error message.

## Preflight + Common Failures (fast fixes)

- Preflight:
  - `command -v uv` (must exist)
  - `test -n "$GEMINI_API_KEY"` (or pass `--api-key`)
  - If editing: `test -f "path/to/input.png"`

- Common failures:
  - `Error: No API key provided.` → set `GEMINI_API_KEY` or pass `--api-key`
  - `Error loading input image:` → wrong path / unreadable file; verify `--input-image` points to a real image
  - `models/... is not found for API version v1` → a `-preview` or retired model id; use `--model flash`, `--model pro`, or another GA id
  - “quota/permission/403” style API errors → wrong key, no access, or quota exceeded; try a different key/account

## Filename Generation

Generate filenames with the pattern: `yyyy-mm-dd-hh-mm-ss-name.png`

**Format:** `{timestamp}-{descriptive-name}.png`
- Timestamp: Current date/time in format `yyyy-mm-dd-hh-mm-ss` (24-hour format)
- Name: Descriptive lowercase text with hyphens
- Keep the descriptive part concise (1-5 words typically)
- Use context from user's prompt or conversation
- If unclear, use random identifier (e.g., `x9k2`, `a7b3`)

Examples:
- Prompt "A serene Japanese garden" → `2025-11-23-14-23-05-japanese-garden.png`
- Prompt "sunset over mountains" → `2025-11-23-15-30-12-sunset-mountains.png`
- Prompt "create an image of a robot" → `2025-11-23-16-45-33-robot.png`
- Unclear context → `2025-11-23-17-12-48-x9k2.png`

## Image Editing

When the user wants to modify an existing image:
1. Check if they provide an image path or reference an image in the current directory
2. Use `--input-image` parameter with the path to the image
3. The prompt should contain editing instructions (e.g., "make the sky more dramatic", "remove the person", "change to cartoon style")
4. Common editing tasks: add/remove elements, change style, adjust colors, blur background, etc.
5. For photoreal object insertion into real photos, prefer `--model pro`

## Prompt Handling

**For generation:** Pass user's image description as-is to `--prompt`. Only rework if clearly insufficient.

**For editing:** Pass editing instructions in `--prompt` (e.g., "add a rainbow in the sky", "make it look like a watercolor painting")

Preserve user's creative intent in both cases.

## Prompt Templates (high hit-rate)

Use templates when the user is vague or when edits must be precise.

- Generation template:
  - “Create an image of: <subject>. Style: <style>. Composition: <camera/shot>. Lighting: <lighting>. Background: <background>. Color palette: <palette>. Avoid: <list>.”

- Editing template (preserve everything else):
  - “Change ONLY: <single change>. Keep identical: subject, composition/crop, pose, lighting, color palette, background, text, and overall style. Do not add new objects. If text exists, keep it unchanged.”

## Output

- Saves PNG to current directory (or specified path if filename includes directory)
- Requires a new filename: existing files, hard links, and symlinks are rejected. Parent directories are created as needed, but symlinked path components are rejected; use their real directory paths instead. Absolute paths and paths outside the current directory remain supported on macOS and Linux.
- Script outputs the model used and the full path to the generated image
- **Do not read the image back** - just inform the user of the saved path

Offline regression tests for output safety and model selection (Pillow required), from the repository root: `python3 -m unittest discover -s skills/nano-banana-pro/scripts -p 'test_*.py'`, or without a local Pillow: `uv run --no-project --with 'pillow>=10.0.0' python -m unittest discover -s skills/nano-banana-pro/scripts -p 'test_*.py'`.

## Examples

**Generate new image:**
```bash
uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "A serene Japanese garden with cherry blossoms" --filename "2025-11-23-14-23-05-japanese-garden.png" --resolution 4K
```

**Edit existing image:**
```bash
uv run "$SKILL_DIR/scripts/generate_image.py" --prompt "make the sky more dramatic with storm clouds" --filename "2025-11-23-14-25-30-dramatic-sky.png" --input-image "original-photo.jpg" --resolution 2K
```

**Photoreal insertion with Nano Banana Pro:**
```bash
uv run "$SKILL_DIR/scripts/generate_image.py" --model pro --prompt "Add a teak outdoor dining table with four chairs on the patio. Match the photo's perspective, lighting, and shadows. Keep everything else identical." --filename "2025-11-23-14-30-10-patio-table.png" --input-image "patio.jpg" --resolution 2K
```
