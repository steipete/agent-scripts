---
name: video-transcript-downloader
description: "yt-dlp downloads: video, audio, subtitles, transcripts, clips, playlists."
---

# Video Transcript Downloader

`./scripts/vtd.js` can:
- Print a transcript as a clean paragraph (timestamps optional).
- Download video/audio/subtitles.

Transcript behavior:
- YouTube: fetch via `youtube-transcript-plus` when possible.
- Otherwise: pull subtitles via `yt-dlp`, then clean into a paragraph, including with `--timestamps`. Empty cleaned subtitles exit with an error and remove their temporary files.

## Setup

```bash
cd ~/Projects/agent-scripts/skills/video-transcript-downloader && npm ci
```

CLI syntax:

```bash
./scripts/vtd.js --help
./scripts/vtd.js transcript --help
```

Subcommands support focused help without requiring `--url`.

## Transcript (default: clean paragraph)

```bash
./scripts/vtd.js transcript --url 'https://…'
./scripts/vtd.js transcript --url 'https://…' --lang en
./scripts/vtd.js transcript --url 'https://…' --timestamps
./scripts/vtd.js transcript --url 'https://…' --keep-brackets
```

## Download video / audio / subtitles

```bash
./scripts/vtd.js download --url 'https://…' --output-dir ~/Downloads
./scripts/vtd.js audio --url 'https://…' --output-dir ~/Downloads
./scripts/vtd.js subs --url 'https://…' --output-dir ~/Downloads --lang en
```

## Formats (list + choose)

List available formats (format ids, resolution, container, audio-only, etc):

```bash
./scripts/vtd.js formats --url 'https://…'
```

Download a specific format id (example):

```bash
./scripts/vtd.js download --url 'https://…' --output-dir ~/Downloads -- --format 137+140
```

Prefer MP4 container without re-encoding (remux when possible):

```bash
./scripts/vtd.js download --url 'https://…' --output-dir ~/Downloads -- --remux-video mp4
```

## Notes

- Default transcript output is a single paragraph. Use `--timestamps` only when asked.
- Bracketed cues like `[Music]` are stripped by default; keep them via `--keep-brackets`.
- Pass extra `yt-dlp` args after `--` for `transcript` fallback, `download`, `audio`, `subs`, `formats`.

```bash
./scripts/vtd.js formats --url 'https://…' -- -v
```

## Troubleshooting (only when needed)

- Missing `yt-dlp` / `ffmpeg`:

```bash
brew install yt-dlp ffmpeg
```

- Verify:

```bash
yt-dlp --version
ffmpeg -version | head -n 1
```
