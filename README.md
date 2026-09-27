# AI Companion

Personal project (not a BYC product). Home of **The List**: a macOS menu bar todo list that Claude fills in, with a draggable pixel dog.

- What and why: [PRD - The List.md](PRD%20-%20The%20List.md)
- Build plan, story by story: [EPICS - The List.md](EPICS%20-%20The%20List.md)
- Clickable prototype: https://claude.ai/artifact/AZmj3cmg19fGAU6PxZPBkb

## Layout

| Folder | What goes here |
|---|---|
| `spec/` | The `TODO.md` format spec (`format.md`) and `fixtures/`: example files with expected parse results. The MCP server and the app both test against these. |
| `mcp/` | `the-list-mcp`, the local MCP server Claude uses to add, list, and finish tasks. |
| `app/` | The List, the SwiftUI menu bar app. |
| `pet/` | Dog sprite sheets. |
| `data/` | **My real tasks.** `TODO.md`, `settings.json`, `archive/`. Gitignored. |

## Data

- `data/TODO.md` is the single source of truth. It's plain Markdown and safe to edit by hand.
- `data/settings.json` holds `proactive` (`true`/`false`). When `false`, Claude stops suggesting tasks but still adds the ones I ask for.
- `data/archive/` gets Done items older than 14 days, one file per month.

## Stack

| Piece | Choice | Notes |
|---|---|---|
| `mcp/` | TypeScript on Node, official `@modelcontextprotocol/sdk`, stdio transport | Node 20.14 confirmed installed. `npm init`, one dependency (the SDK) plus a test runner. |
| `app/` | Swift 6.2, SwiftUI, `MenuBarExtra`, macOS 26 target | Swift toolchain confirmed (6.2.3), but only the Command Line Tools are installed — **no Xcode.app**. Building a `MenuBarExtra` app needs full Xcode (App Store) for the app target and code signing; the CLI tools alone aren't enough. Install Xcode before starting E4. |
| Tests | Node's built-in test runner (`node --test`) for `mcp/`; XCTest for `app/`; both run against `spec/fixtures/` (E0.2) | No extra test framework dependency needed on either side. |
| Package manager | npm (`mcp/`), Swift Package Manager (`app/`) | No Xcode project file until E4.1; `app/` stays empty until then. |

Nothing else pulled in — this stays a small, native, offline app per the PRD's non-goals.
