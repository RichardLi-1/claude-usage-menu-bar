# Claude Usage Menu Bar

A macOS menu bar app that shows your Claude account usage at a glance.

![macOS menu bar showing Claude usage](https://placeholder)

## Features

- **Plan usage bars** — session (5-hour), weekly, and Claude Design limits pulled live from claude.ai
- **Claude Code costs** — today / this week / this month, parsed from local `~/.claude/projects/` JSONL files
- **Auto auth** — reads credentials from Claude Desktop's encrypted cookie store (no manual setup needed if you use Claude Desktop)
- **Manual auth** — paste a session token and org ID if you don't use Claude Desktop
- Configurable refresh interval (1 / 5 / 15 / 30 minutes)
- Toggles to show/hide plan usage and cost sections independently

## Requirements

- macOS 13 Ventura or later (Apple Silicon)
- Claude Desktop installed, **or** a session token + org ID from claude.ai

## Build

```bash
bash build.sh
```

Produces `ClaudeUsage.app` (~350 KB, self-contained, ad-hoc signed).

```bash
open ClaudeUsage.app
```

On first launch macOS will ask you to confirm opening an unsigned app — click **Open**.

## Configuration

Click the menu bar item → **Settings…**

| Setting | Description |
|---|---|
| Source: Claude Desktop | Reads credentials automatically from `~/Library/Application Support/Claude/Cookies` |
| Source: Manual token | Enter `sessionKey` and `lastActiveOrg` cookies from claude.ai |
| Refresh interval | How often to fetch plan usage from the API |
| Show plan usage | Toggle the session/weekly/design progress bars |
| Show Claude Code cost | Toggle the local cost breakdown |

**Finding manual credentials:**  
Open claude.ai in your browser → DevTools (F12) → Application → Cookies → `https://claude.ai`.  
Copy `sessionKey` and `lastActiveOrg`.

## Distribute

```bash
zip -r ClaudeUsage.zip ClaudeUsage.app
```

Send the zip. Recipients double-click to unzip, then right-click → Open on first launch to bypass Gatekeeper.

## How it works

- **Plan usage** — authenticated GET to `claude.ai/api/organizations/{orgId}/usage`, using cookies decrypted from Claude Desktop's Chromium cookie store (PBKDF2-SHA1 + AES-128-CBC, key from the macOS keychain entry "Claude Safe Storage").
- **Local costs** — scans `~/.claude/projects/**/*.jsonl`, finds `assistant` entries with `message.usage` fields, calculates cost using published Claude pricing, deduplicates by `message.id`.
