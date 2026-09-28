# Epics & User Stories — The List

| | |
|---|---|
| Source | [PRD - The List.md](PRD%20-%20The%20List.md) (v0.3) |
| Date | 2026-09-26 |
| Status | Draft v0.1 |

How to use this: build the stories **in order, top to bottom**. Each story leaves the product in a working state, so you can stop after any one of them and still use what exists. Checkpoints mark the points where the product becomes noticeably more useful.

Each story heading shows: size · **model** · [PRD requirement IDs].

Sizes: **S** = under 2 hours, **M** = half a day, **L** = about a day (building with Claude Code).

### Which model builds what

| Model | Used for | Stories |
|---|---|---|
| **Haiku** | Mechanical work with an obvious right answer: setup, config, small UI additions on top of existing code | 10 |
| **Sonnet** | Standard coding against a clear spec and tests: parsers, MCP tools, SwiftUI screens | 18 |
| **Opus** | Judgment calls and code where a subtle mistake costs data or hours: the file format spec, concurrent writes, how Claude decides what's your task, per-pixel click-through, the session-resume spike | 6 |

Two rules on top of the per-story pick:
- **Opus reviews at every checkpoint.** Haiku and Sonnet stories get checked against their acceptance criteria before the next story starts.
- **Step up after two failed tries.** If a Haiku story fails its checks twice, retry it on Sonnet; if a Sonnet story fails twice, retry on Opus.

---

## Overview

| Epic | Goal | Stories | Milestone |
|---|---|---|---|
| **E0 — Foundation** | Folder layout, file format spec, shared test fixtures | 3 | M1 |
| **E1 — The file** | `TODO.md` that can be read and written safely | 3 | M1 |
| **E2 — Capture (MCP server)** | Claude can add, list, finish, and update tasks | 5 | M1 |
| **E3 — Claude behavior** | Claude notices my tasks, asks first, and respects the on/off switch | 4 | M1 |
| **E4 — Menu bar app** | The List shows in the menu bar and stays in sync with the file | 4 | M2 |
| **E5 — Acting on tasks** | Tick, re-prioritize, quick-add, click through to links | 4 | M2 |
| **E6 — The dog** | Draggable pixel dog that reacts to the list | 6 | M3 |
| **E7 — Polish** | Settings, archive, session resume, launch at login, widget | 5 | M4 |

**Total:** 34 stories. Rough effort: M1 ≈ 3 days, M2 ≈ 3 days, M3 ≈ 3 days, M4 ≈ 3 days.

---

## Two recommendations before you start

**1. Keep runtime data in a `data/` subfolder.** The PRD puts `TODO.md` directly in `AI Companion/`. If this folder becomes a git repo (PRD open question 1), your personal tasks would sit next to the code and could get committed. Suggested layout:

```
AI Companion/
├── PRD - The List.md
├── EPICS - The List.md
├── spec/            format.md + fixtures/ (shared by MCP server and app)
├── mcp/             the-list-mcp (TypeScript)
├── app/             The List (Xcode / SwiftUI)
├── pet/             dog sprites
└── data/            TODO.md, settings.json, archive/   ← gitignored
```

If you agree, update PRD §6.1 to `AI Companion/data/TODO.md`. The stories below assume this layout.

**2. The file format needs one spec and one set of test files.** The MCP server (TypeScript) and the app (Swift) each parse `TODO.md`, in two languages. If they disagree even slightly, one will corrupt what the other wrote. Story E0.2 writes a set of example files with expected results, and both parsers test against the same set.

---

## E0 — Foundation

### E0.1 Project scaffold · S · **Haiku**
*As the builder, I want a clear folder layout so that code, docs, and my personal data don't mix.*
- [x] Folders created as in the layout above.
- [x] `data/` holds a starter `TODO.md` with the five headings (P0–P3, Done) and a `settings.json` with `{"proactive": true}`.
- [x] A `.gitignore` excludes `data/` (ready for when this becomes a repo).
- [x] A short `README.md` explains the layout and points to the PRD.

### E0.2 File format spec + golden fixtures · M · **Opus** · [D1–D3]
*As the builder, I want one written spec and a set of test files so that both parsers agree on every edge case.*
- [x] `spec/format.md` defines: headings, checkbox syntax, the `{key:value}` metadata block, allowed keys, date format (`YYYY-MM-DD`), and how to treat anything unrecognized (keep it untouched).
- [x] `spec/fixtures/` contains pairs of `input.md` + `expected.json`, covering at least: a normal file, hand-typed lines with no metadata, a title containing `{` or `}`, an unknown heading, extra blank lines, CRLF line endings, an empty file, and an item under the wrong heading.
- [x] Round-trip rule: parse → write → parse gives the same result, and lines the parser didn't change keep their exact bytes.

### E0.3 Pick the stack · S · **Haiku**
*As the builder, I want the tech choices written down so that I don't re-decide them mid-build.*
- [x] MCP server: TypeScript + the official MCP SDK, stdio transport (recommended; Python also works).
- [x] App: SwiftUI, macOS 26 target, `MenuBarExtra`.
- [x] Choices recorded in `README.md`.

---

## E1 — The file

### E1.1 Parser + writer (TypeScript) · M · **Sonnet** · [D1–D3]
*As the MCP server, I want to read and write `TODO.md` exactly per spec so that Claude's edits never damage the file.*
- [x] Passes every fixture in `spec/fixtures/`.
- [x] Hand-typed lines get an `id` the next time the file is written (D3).
- [x] Unknown content is kept as it was.

### E1.2 Safe writes · S · **Sonnet** · [D4]
*As the user, I want writes to never corrupt the file so that I never lose a task.*
- [x] Every write goes to a temp file and then renames it over `TODO.md`.
- [x] Killing the process mid-write leaves either the old file or the new one, never a half-written file.

### E1.3 No lost updates · S · **Opus** · [D4]
*As the user, I want edits from the app, Claude, and my own editor to never overwrite each other.*
- [x] Every change re-reads the file right before writing and applies itself to that fresh copy. It never writes back an old copy held in memory.
- [x] Test: two writers add different items 10 ms apart → both items are in the file.

> **Checkpoint:** nothing visible yet, but the most dangerous part (data integrity) is done and tested.

---

## E2 — Capture (MCP server)

### E2.1 `add_todo` · M · **Sonnet** · [C1]
*As me, I want to say "put X in my todo list" and have it written to the file.*
- [x] Tool `add_todo(title, priority?, due?, link?, project?, note?)` appends the item under the right heading.
- [x] Defaults: priority P2, `src:claude-code`, `added:<today>`.
- [x] Returns the new item, including its `id`, so Claude can confirm it.

### E2.2 Register with Claude Code · S · **Haiku** · [C2]
*As me, I want the server available in every Claude Code session without extra setup.*
- [x] `claude mcp add --scope user the-list …` works, and the server appears in `/mcp`. (2026-09-27: `claude mcp list` shows `the-list` ✔ Connected. The CLI lives at `~/.local/bin/claude`, now on PATH through `~/.zshrc`.)
- [x] In a fresh session, "put 'test task' in my todo list" writes a correct line to `data/TODO.md`.

> **Checkpoint — first usable version.** Claude writes tasks, and I read `TODO.md` in VS Code. Use it for a day before going further.

### E2.3 `list_todos`, `complete_todo`, `update_todo` · M · **Sonnet** · [C1]
*As me, I want to ask Claude what's on my list, tick things off, and change them without opening the file.*
- [x] `list_todos(filter?)` supports filtering by status, priority, and project, and sorts by effective priority (§6.3: overdue or due today counts as P0).
- [x] `complete_todo(id)` moves the item to Done with `done:<today>`.
- [x] `update_todo(id, …)` changes any field. A priority change moves the line to the new heading.

### E2.4 Duplicate check · S · **Sonnet** · [C7]
*As me, I want Claude to notice when a task is already on the list so that I don't get duplicates.*
- [x] `add_todo` fuzzy-matches the title against open items. On a close match it doesn't add; it returns the existing item and `duplicate: true`.
- [x] Claude then asks "Update the existing one instead?"

### E2.5 Register with Claude Desktop · S · **Haiku** · [C2]
*As me, I want the same capture to work in the Claude Desktop app.*
- [x] Added to `claude_desktop_config.json` (`mcpServers.the-list`, pointing at `mcp/dist/index.js`, `THE_LIST_SRC=claude-desktop`). Restart Claude Desktop and check `the-list`'s tools appear.
- [x] Items added from Desktop carry `src:claude-desktop` — covered by the integration test (`server.integration.test.ts`); confirm once more with a real add from the Desktop app.

---

## E3 — Claude behavior

### E3.1 Global instruction · S · **Opus** · [C3, C4, C5]
*As me, I want Claude to spot tasks that are mine and ask before adding them.*
- [x] The instruction is added to `~/.claude/CLAUDE.md` (text from PRD C3).
- [x] An explicit "put this in my todo list" adds straight away. Anything Claude detects on its own gets proposed with a suggested priority and waits for "yes" (C4).
- [x] Test with 10 sample prompts: tasks that are mine get proposed; tasks Claude is doing itself, tasks owned by others, and vague ideas don't (C5). (Passed in a fresh session, 2026-09-27.)

### E3.2 Priority suggestion · S · **Opus** · [§6.3]
*As me, I want Claude's suggested priority to follow my rules so that I rarely have to correct it.*
- [x] The instruction includes the P0–P3 rules from §6.3.
- [x] Mentions of dates ("by Friday", "tomorrow") become a `due` date.

### E3.3 Auto-link · S · **Sonnet** · [C6]
*As me, I want each task to link back to where it came from.*
- [x] Claude attaches, in this order: the file being worked on (`vscode://file/…`), then a URL from the conversation, then a ClickUp task.
- [x] If none of those exist, the task has no link for now. Session links come in E7.3.

### E3.4 Proactive on/off switch · S · **Sonnet** · [C9]
*As me, I want to turn off Claude's suggestions when they get in the way, without losing explicit adds.*
- [x] `add_todo` still works when `data/settings.json` has `"proactive": false`.
- [x] A new tool `get_settings` returns the settings, and the instruction tells Claude to check it before proposing anything.
- [x] With proactive off, the 10 test prompts produce no proposals, and explicit adds still work. (Passed, 2026-09-27.)
- [x] Until the app's Settings screen exists (E7.1), I flip the switch by editing the JSON or by asking Claude ("turn off todo suggestions").

> **Checkpoint — M1 done.** The whole capture loop works with no app at all.

---

## E4 — Menu bar app

### E4.1 Menu bar shell · M · **Sonnet** · [A1]
*As me, I want The List in my menu bar so that it's always one click away.*
- [ ] A SwiftUI `MenuBarExtra` app with no Dock icon.
- [ ] Clicking the icon opens an empty popover titled "The List".

### E4.2 Swift parser · M · **Sonnet** · [D1–D3]
*As the app, I want to read `TODO.md` exactly the way the MCP server does.*
- [x] Passes every fixture in `spec/fixtures/` (the same set E1.1 uses). Built as `app/TheListCore/` and checked by `swift run fixture-check`: 13 parse and 17 write fixtures. Move these into XCTest once Xcode is installed.
- [x] Writes are safe (E1.2) and don't lose updates (E1.3). It uses the same `TODO.md.lock` protocol as the MCP server. A test runs 30 writes each from Swift and the real TypeScript server at the same time, and none are lost.

### E4.3 Show the list · M · **Sonnet** · [A3, §6.3]
*As me, I want to see my tasks grouped by priority, with the urgent ones first.*
- [ ] Groups for Now, This week, Soon, and Someday, with a count on each.
- [ ] Each row shows the title, project tag, and a relative due date ("Today", "Tomorrow", "Wed", "Overdue 2d").
- [ ] Anything overdue or due today appears under Now, without the file being rewritten.
- *Logic built ahead of Xcode (2026-09-28):* `makeSnapshot` (the four groups with counts, the effective-priority bump, sort order) and `relativeDueLabel` in `TheListCore/ListLogic.swift`, tested in `fixture-check`. The view itself is still to do.

### E4.4 Live sync + badge · M · **Sonnet** · [A2, A6, A9]
*As me, I want the list to update by itself when Claude adds something.*
- [ ] The app watches the file (FSEvents) and updates within 1 second of any outside change.
- [ ] The badge shows the number of open P0 + P1 tasks and turns red when anything is overdue.
- [ ] At idle: under 50 MB of memory and about 0% CPU.
- *Logic built ahead of Xcode (2026-09-28):* `TodoFileWatcher` (FSEvents on the folder; it fires only when the bytes change) and `Badge`. Tested with an atomic rename, an in-place editor save, a real write from the TypeScript server and a delete: each is noticed in about 12 ms, and non-changes are ignored. The memory and CPU budget can only be measured once the app exists.

> **Checkpoint:** a Claude add now shows up in the menu bar within a second.

---

## E5 — Acting on tasks

### E5.1 Tick off · S · **Sonnet** · [A5]
*As me, I want to mark a task done with one click.*
- [ ] Clicking the checkbox moves the item to Done, with `done:<today>`.
- [ ] A collapsible "Done (n)" section; clicking the checkbox again un-ticks an item.

### E5.2 Click through · M · **Sonnet** · [A4, L1, L2, L4]
*As me, I want clicking a task to take me to its context.*
- [ ] `https://` links open in the browser, `vscode://` links open VS Code at that file, and local paths open in Finder.
- [ ] A task with no link opens `TODO.md` in VS Code at that line.
- *Logic built ahead of Xcode (2026-09-28):* `clickTarget(for:todoPath:)` decides what each link opens, including the fallback to TODO.md at the task's line. Actually opening it (`NSWorkspace.open`) comes with the app.

### E5.3 Change priority · S · **Haiku** · [A5]
*As me, I want to move a task between priorities.*
- [ ] A right-click menu offers P0–P3. The line moves to the new heading in the file.
- [ ] Drag-and-drop between groups (optional; the right-click menu is enough for v1).

### E5.4 Quick-add · S · **Haiku** · [A7]
*As me, I want to add a task by hand without Claude.*
- [ ] A text field at the top of the popover. Enter adds the task as P2 with `src:manual`.

> **Checkpoint — M2 done.** Daily driver: I no longer open the `.md` file directly.

---

## E6 — The dog

### E6.1 Floating pet window · M · **Opus** · [P1]
*As me, I want a small window on my desktop where the dog lives.*
- [ ] A transparent, borderless, always-on-top panel about 64–96 px wide, visible on all Spaces.
- [ ] Only the dog's own pixels take clicks. Clicks anywhere else in the window reach whatever is behind it.

### E6.2 Dog sprite sheet · M · **Sonnet** · [P4, P8]
*As me, I want the dog's art ready for every state.*
- [ ] Frames generated with AI image tools, using the prototype's 16×12 dog as the reference: walk (2 frames), run (2), sit/wag (2), sleep (1), jump (1), held (1).
- [ ] Claude models can't generate images. Either you generate the frames with an image tool and Sonnet slices them into a sheet, or Sonnet writes a script that renders the sheet from pixel grids, the way the prototype draws the dog.
- [ ] Exported as a PNG sheet and drawn with nearest-neighbor scaling (no blur) at 8–12 fps.

### E6.3 Drag anywhere · M · **Sonnet** · [P2, P3]
*As me, I want to put the dog wherever I like.*
- [ ] Dragging moves it to any spot on any screen. While held, it shows the "held" frame.
- [ ] Its position is saved and restored after a restart.
- [ ] A press without movement opens the list popover.

### E6.4 States from the list · M · **Sonnet** · [P5]
*As me, I want the dog to show at a glance how urgent my list is.*
- [ ] Highest-priority state wins: **Jump** (~2 s after an add or finish) → **Run in place** (any effective P0 is open; bubble shows e.g. "2 in Now!") → **Walk** (open tasks, none P0; stays within ~90 px of its spot) → **Sleep** (list empty).
- [ ] States update within 1 second of any change to the file.

### E6.5 Show / hide · S · **Haiku** · [P6]
*As me, I want to hide the dog quickly, for example before a screen-share.*
- [ ] A toggle in the popover footer and a global hotkey (default to be decided; PRD open question 3).
- [ ] Hidden or shown is remembered across restarts.

### E6.6 Reduce Motion · S · **Haiku** · [P7]
*As me, I want the dog to respect my Mac's Reduce Motion setting.*
- [ ] With Reduce Motion on: no walking or bouncing, but the pose still changes with each state.

> **Checkpoint — M3 done.** Matches the prototype.

---

## E7 — Polish

### E7.1 Settings screen · M · **Sonnet** · [A8, C9]
*As me, I want one place to change how The List behaves.*
- [ ] Settings: file location, launch at login, pet on/off, reset pet position, archive window (days), **proactive suggestions on/off**.
- [ ] The proactive switch writes to `data/settings.json`, so Claude picks up the change on its next check.

### E7.2 Archive · S · **Haiku** · [D5]
*As me, I want old Done items cleared out so that the file stays short.*
- [x] Done items older than 14 days (configurable) move to `data/archive/YYYY-MM.md`. This is `archiveOldDone` in `TheListCore`, specified in spec §3.6 and covered by 7 checks in `fixture-check`. It is safe to run repeatedly and survives a crash partway through.
- [ ] Runs when the app starts and once a day. This is a single call from the app, so it lands with E4.1.

### E7.3 Session resume links · L · **Opus** · [L3, C6]
*As me, I want a task to reopen the Claude Code session it came from.*
- [x] **Spike first (S):** check whether the MCP server can learn the current Claude Code session id, for example from an environment variable or through a hook. If it can't, drop this story.
  **Result (2026-09-28): it can, so the story stays.** Claude Code 2.1.283 starts each MCP server with `CLAUDE_CODE_SESSION_ID` in its environment. I checked the live `the-list` server behind a running session: its variable held that session's id, and the transcript `~/.claude/projects/<folder>/<id>.jsonl` carries the same id. No hook is needed.
  - **Resume has to run in the session's folder.** Sessions are stored per project, so run `cd <cwd> && claude --resume <id>`. The folder name in `~/.claude/projects/` is a lossy encoding (spaces become `-`), so get `cwd` from the transcript's first entry instead. The app can find the transcript by id alone, which keeps the link short.
  - **A running session may have no transcript yet.** One open VS Code panel had a server and an id but no file, because Claude Code writes the file on the first message. By the time `add_todo` runs there has been a message, but the app should still say "session no longer available" when the file is missing, for example after it's been deleted.
  - **Claude Desktop chats get no session link.** Desktop isn't Claude Code and its chats can't be resumed with the CLI. When the variable is absent, the server adds no link.
  - **Untested risk: `/clear`.** `/clear` starts a new session id. If the MCP server keeps running across `/clear`, its variable still holds the old id, and new tasks would link to the conversation before the clear. I can't test this without clearing a live session. Check it by hand before building: in a fresh session, add a task, run `/clear`, add another, and compare the ids against the transcript files. If it's stale, a `PreToolUse` hook on `mcp__the-list__add_todo` receives the live `session_id` and can pass it along.
  - **Opening Terminal:** use a temporary `.command` script opened with `open`, not AppleScript. AppleScript would trigger a macOS Automation permission prompt.
- [ ] If the spike succeeds: tasks carry `link:thelist://session/<id>`, the app registers the `thelist://` scheme, and clicking a task opens Terminal and runs `claude --resume <id>`.

### E7.4 Launch at login · S · **Haiku** · [A1]
*As me, I want The List running whenever my Mac is on.*
- [ ] A "Launch at login" option (off by default) using `SMAppService`.

### E7.5 Desktop widget (optional) · M · **Sonnet** · [§6.4 optional]
*As me, I want my top tasks visible on the desktop without clicking anything.*
- [ ] A WidgetKit widget showing the top 5 items by effective priority.
- [ ] Clicking a task opens its link.

> **Checkpoint — M4 done.** v1 complete.

---

## Deferred to v2 (PRD §10)

Not broken into stories yet: capture from claude.ai web/mobile, a morning digest, more pets and skins, and natural-language due dates in quick-add.
