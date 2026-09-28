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
| `app/` | The List, the SwiftUI menu bar app. `app/TheListCore/` is its Swift package for reading and writing `TODO.md`, and it builds without Xcode. |
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
| Tests | Node's built-in test runner (`node --test`) for `mcp/`; for `app/`, a `fixture-check` executable for now, XCTest once Xcode is installed. Both run against `spec/fixtures/` (E0.2). | The Command Line Tools ship neither XCTest nor Swift Testing, so `swift run fixture-check` stands in until then. It exits with status 1 on any failure. |
| Package manager | npm (`mcp/`), Swift Package Manager (`app/`) | `app/TheListCore/` is a Swift package. The app target and the Xcode project come in E4.1. |

### Running the checks

```bash
(cd mcp && npm test)                              # TypeScript: parse and write fixtures, unit and integration tests
(cd app/TheListCore && swift run fixture-check)   # Swift: parse and write fixtures, file-safety checks, a concurrent-write test against mcp/dist
python3 spec/reference.py                         # Python reference: parse fixtures only
```

The Swift concurrent-write test uses the built server in `mcp/dist`, so run `npm run build` (or `npm test`) in `mcp/` first.

Nothing else pulled in — this stays a small, native, offline app per the PRD's non-goals.
