---
name: xurl
description: "xurl X API CLI: install, auth, app choice, shortcuts, raw endpoints."
metadata:
  {
    "openclaw":
      {
        "emoji": "X",
        "requires": { "bins": ["xurl"] },
        "install":
          [
            {
              "id": "brew",
              "kind": "brew",
              "formula": "xdevplatform/tap/xurl",
              "bins": ["xurl"],
              "label": "Install xurl (brew)",
            },
            {
              "id": "npm",
              "kind": "node",
              "package": "@xdevplatform/xurl",
              "bins": ["xurl"],
              "label": "Install xurl (npm)",
            },
          ],
      },
  }
---

# xurl

Official CLI for the X API.

Primary upstream: <https://github.com/xdevplatform/xurl>

## Install

Homebrew:

```bash
brew install --cask xdevplatform/tap/xurl
```

npm:

```bash
npm install -g @xdevplatform/xurl
```

Shell script:

```bash
curl -fsSL https://raw.githubusercontent.com/xdevplatform/xurl/main/install.sh | bash
```

Go:

```bash
go install github.com/xdevplatform/xurl@latest
```

## Safety

- Never read, print, summarize, upload, or paste `~/.xurl` into LLM context.
- Never ask the user to paste client secrets, bearer tokens, or OAuth tokens into chat.
- Never use `--verbose` in agent runs; it can expose auth headers.
- Do not run auth commands with inline secret flags in an agent session.
- The user must register app credentials manually on their machine outside the agent session.

## Auth

Check current state:

```bash
xurl auth status
```

If an app is already registered, complete OAuth 2.0:

```bash
xurl auth oauth2
```

Multi-app:

```bash
xurl auth apps list
xurl auth default my-app
xurl auth default my-app alice
xurl --app dev-app /2/users/me
```

Notes:

- `xurl` stores app config and tokens in `~/.xurl`.
- OAuth 2.0 redirect URI in the X developer portal should be `http://localhost:8080/callback`.
- App registration examples with inline secrets are intentionally omitted here. Do that outside the agent session.

## Common shortcuts

```bash
xurl post "Hello world!"
xurl reply 1234567890 "Nice post"
xurl quote 1234567890 "My take"
xurl delete 1234567890

xurl read 1234567890
xurl search "from:elonmusk" -n 10
xurl whoami
xurl user @XDevelopers
xurl timeline -n 20
xurl mentions -n 10

xurl like 1234567890
xurl unlike 1234567890
xurl repost 1234567890
xurl unrepost 1234567890

xurl bookmark 1234567890
xurl unbookmark 1234567890
xurl bookmarks -n 10
xurl likes -n 10

xurl follow @handle
xurl unfollow @handle
xurl following -n 20
xurl followers -n 20

xurl dm @handle "message"
xurl dms -n 10

xurl media upload path/to/file.mp4
xurl media status MEDIA_ID
```

`POST_ID` can also be a full X status URL.

## Raw endpoint mode

GET:

```bash
xurl /2/users/me
```

POST JSON:

```bash
xurl -X POST /2/tweets -d '{"text":"Hello world!"}'
```

Headers:

```bash
xurl -H "Content-Type: application/json" /2/tweets
```

Choose auth type:

```bash
xurl --auth oauth2 /2/users/me
xurl --auth oauth1 /2/tweets
xurl --auth app /2/users/me
```

Choose OAuth2 account:

```bash
xurl --username alice /2/users/me
```

Streaming:

```bash
xurl /2/tweets/search/stream
xurl -s /2/users/me
```

## Quick checks

Install:

```bash
xurl version
```

Auth:

```bash
xurl auth status
```

Live request after auth:

```bash
xurl whoami
```
