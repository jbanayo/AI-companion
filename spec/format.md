# TODO.md format spec

| | |
|---|---|
| Version | 1.0 |
| Date | 2026-09-26 |
| Used by | `mcp/` (TypeScript), `app/` (Swift), `spec/reference.py` |
| PRD | §6.1, D1–D4 |

This is the contract for reading and writing `data/TODO.md`. The MCP server and the app must both behave exactly as described here. `spec/fixtures/` holds the test cases, and `spec/reference.py` is a small executable version of this spec that checks them. If this document and the fixtures ever disagree, fix whichever is wrong, then make both implementations pass again.

**Two principles:**
1. **Never lose what I wrote.** Anything the parser doesn't understand is kept exactly as it was.
2. **Touch only what changed.** Writing the file changes only the lines an operation actually modified. Every other line keeps its exact bytes.

---

## 1. Example

```markdown
# Todo

## P0 — Now
- [ ] Reply to Enzo on Prismo pricing ruling {id:t_8f2a due:2026-09-27 src:claude-code link:https://app.clickup.com/t/abc123}

## P1 — This week
- [ ] Review Solomon extract PR #42 {id:t_1c9d due:2026-10-01 src:claude-desktop}
  Check the OCR fallback path first.

## P2 — Soon

## P3 — Someday

## Done
- [x] Push product-docs update {id:t_0a11 done:2026-09-25}
```

---

## 2. Reading the file

### 2.1 Encoding and line endings

- The file is UTF-8. A leading byte-order mark (BOM) is removed when reading and put back when writing (`bom: true`).
- **Line ending:** the ending of the first line decides the whole file. If it's `\r\n`, the file is `crlf`; otherwise `lf`. An empty file, or one with a single line and no ending, is `lf`.
- **Final newline:** whether the file ends with a line ending is recorded (`finalNewline`) and kept on write.
- Lines are split on `\n`, and a trailing `\r` is removed from each line.

### 2.2 Line types

Every line is exactly one of these, checked in this order:

| Type | Rule |
|---|---|
| **Heading** | Starts with `## ` (two `#`, then whitespace). Only level-2 headings count; `#` and `###` lines are *other* lines. |
| **Item** | Matches `^[-*+][ \t]+\[( \|x\|X)\][ \t]+(.+)$` (bullet, whitespace, checkbox, whitespace, content) and has a non-empty title (§2.5). No leading indentation. |
| **Body** | Starts with 2+ spaces or a tab, isn't blank, and comes directly after an item or after another body line of that item. It belongs to that item. |
| **Other** | Anything else: blank lines, `# Todo`, paragraphs, indented lines that don't follow an item, items with an empty title. Kept as-is. |

A blank line ends an item's body.

### 2.3 Sections

A heading (a line already identified as level-2 per §2.2) is **known** if the text right after `## ` starts with `P0`, `P1`, `P2`, `P3`, or `Done`, case-insensitively, at a word boundary — i.e. that word isn't immediately followed by another letter, digit, or underscore:

```
^(P0|P1|P2|P3|Done)\b
```

applied to the heading's text after its `## ` prefix. There's no requirement on what follows the boundary: it can be nothing, a dash and a comment, a colon, an emoji, anything.

So `## P1 — This week`, `## p1`, `## P1 - later`, `## P1: stuff`, and `## Done ✅` are all known (`P1`, `P1`, `P1`, `P1`, `Done`). `## P12` is **unknown** — `P1` is immediately followed by `2`, another word character, so there's no boundary there. `## Ideas` is unknown too, for the obvious reason (doesn't start with any of the five words).

- Every line belongs to the section of the nearest heading above it.
- Lines before the first heading, and lines under an unknown heading, have section `null`.
- If a known heading appears twice, both count as that section. New items go to the first one.
- Everything from the word boundary onward (`— Now`, `: stuff`, ` ✅`, …) is display only and is never rewritten.

### 2.4 Priority and done status

- **The checkbox decides done status.** `[x]` or `[X]` means done, `[ ]` means open. Where the item sits doesn't change this.
- **The section decides priority for anything under a known heading** (P0–P3 or Done) — an item's priority is that heading's key, whether the item is open or done. An item under `## Done` shows priority `Done` even if it's still `[ ]` open; an item under `## P1` shows priority `P1` even if it's `[x]` done.
- **Under an unknown heading, or before any heading,** priority is `P2`, regardless of done status. (There's no `null` priority — every item always displays in some group.)

A done item sitting under P1, or an open item under Done, stays where it is. The parser doesn't move anything. It moves only when an operation touches it.

> Display rule, not a parser rule: the app and `list_todos` show an open item with a valid `due` of today or earlier as P0 ("effective priority", PRD §6.3). The file isn't rewritten for this.

### 2.5 Title and metadata block

An item's content (everything after the checkbox) is split into a **title** and an optional **metadata block**.

The metadata block is the **shortest suffix** of the content that:
1. starts with `{` and is preceded by at least one space or tab,
2. ends at the end of the content (trailing whitespace ignored), and
3. matches this grammar as a whole:

```
block  = "{" ws* pair ( ws+ pair )* ws* "}"
pair   = key ":" value
key    = [a-z] [a-z0-9_]*
value  = quoted | bare
bare   = one or more characters that aren't whitespace, "{", "}", or '"'
quoted = '"' ( any character except '"' and '\' | '\"' | '\\' )* '"'
```

The **title** is everything before the block, with whitespace trimmed at both ends. If no suffix qualifies, there is no block and the whole content (trimmed) is the title. An item needs a non-empty title; otherwise the line is an *other* line.

Examples:

| Content | Title | Metadata |
|---|---|---|
| `Fix {braces} in template {id:t_aa01}` | `Fix {braces} in template` | `id=t_aa01` |
| `Reply to {Enzo}` | `Reply to {Enzo}` | none (no `key:` inside) |
| `Check {x:1} {id:t_bb02}` | `Check {x:1}` | `id=t_bb02` |
| `Check {x:1}` | `Check` | `x=1` (see note) |
| `Call {note:"ask about {rates}" id:t_cc03}` | `Call` | `note=ask about {rates}`, `id=t_cc03` |
| `Tidy{id:t_dd04}` | `Tidy{id:t_dd04}` | none (no space before `{`) |

Note: a trailing `{word:value}` is always read as metadata. This is never a problem for items the program writes, because the writer always ends the line with its own block (with at least `id`), so a `{x:1}` in the title is never last.

**Values:** quoted values are stored without the quotes, with `\"` → `"` and `\\` → `\`. If a key appears twice in one block, the last one wins.

### 2.6 Metadata keys

| Key | Meaning | Format |
|---|---|---|
| `id` | Stable identifier | Any value. Generated ids are `t_` + 4 lowercase hex characters. |
| `due` | Due date | `YYYY-MM-DD` |
| `done` | Date completed | `YYYY-MM-DD` |
| `added` | Date added | `YYYY-MM-DD` |
| `project` | Project tag | e.g. `solomon`, `lumen`, `personal` |
| `src` | Where it came from | `claude-code`, `claude-desktop`, `manual` |
| `link` | What clicking opens | URL, `vscode://…`, `thelist://…`, or a path. Spaces must be `%20`-encoded or the value quoted. |
| `note` | Free text | Usually quoted |

- **Unknown keys are kept** and written back in their original order after the known keys.
- **Dates are stored as written.** A date that isn't a real `YYYY-MM-DD` date is kept in the file but ignored by sorting, overdue checks, and archiving.

### 2.7 IDs

- An item with no `id` has id `null`.
- **Duplicate ids:** if two items have the same id, the first one (top to bottom) keeps it. Every later one is read as id `null`, and its `id` key is left out of its metadata.
- Items with id `null` get a new id the next time an operation runs (§3.2).

---

## 3. Writing the file

### 3.1 Serialize

`serialize(parse(file))` must return the **exact original bytes** when no operation has run, for any LF-only or CRLF-only file. (A file that mixes line endings is normalized to the first line's ending on its first write. That's the one exception.)

Each line is written with the file's line ending. The final newline and BOM are kept as they were.

### 3.2 Operations

Every operation first runs **assignMissingIds**, then does its own change. Lines not touched by either keep their exact bytes.

| Operation | What it does |
|---|---|
| `assignMissingIds` | Gives every item with id `null` a new id and re-renders that line (§3.3). |
| `add(item)` | Renders a new open item and inserts it into its priority section (§3.4). |
| `complete(id, date)` | Sets `[x]` and `done:<date>`, removes the item (with its body) from where it is, and inserts it at the **top** of Done. |
| `reopen(id, priority)` | Sets `[ ]`, removes `done`, and moves the item to the end of the given priority section (default P2). |
| `update(id, fields)` | Changes fields and re-renders the line in place. If `priority` changes, the item (with its body) moves to the **end** of the new section. Setting a field to `null` removes it. |
| `remove(id)` | Deletes the item and its body lines. |

When an item moves or is removed, only its own line and body lines go. Blank lines around it stay as they are.

### 3.3 Rendering an item line

A line an operation touches is rendered in this canonical form:

```
- [ ] <title> {<pairs>}
- [x] <title> {<pairs>}
```

- The bullet is `-`, and the checkbox is lowercase `x`.
- The title is trimmed.
- **Pair order:** `id`, `due`, `done`, `added`, `project`, `src`, `link`, `note`, then unknown keys in their original order.
- A value is written **quoted** if it's empty or contains whitespace, `{`, `}`, or `"`. Inside quotes, `"` becomes `\"` and `\` becomes `\\`. Every other value is written bare.
- Body lines are never rewritten.

### 3.4 Where new and moved items go

**Into an existing section:** directly after the last item of the first heading with that key (after that item's body lines). If the section has no items, directly after the heading line.

**Missing section:** if the target heading doesn't exist, insert it using its canonical text:

| Key | Canonical heading |
|---|---|
| P0 | `## P0 — Now` |
| P1 | `## P1 — This week` |
| P2 | `## P2 — Soon` |
| P3 | `## P3 — Someday` |
| Done | `## Done` |

Place it directly **before the next known heading that comes after it** in the order P0, P1, P2, P3, Done, followed by the item and one blank line. If no later known heading exists, add it at the end of the file: first a blank line (if the file isn't empty and its last line isn't blank), then the heading, then the item.

**Empty file:** if the file has no non-blank lines, the writer first replaces it with the skeleton below, then inserts as normal. A new file gets `lf` endings and a final newline.

```markdown
# Todo

## P0 — Now

## P1 — This week

## P2 — Soon

## P3 — Someday

## Done
```

### 3.5 Safety (PRD D4)

These are implementation rules. The fixtures can't test them, so each implementation needs its own tests (stories E1.2, E1.3).

- **Atomic writes:** write to a temp file in the same folder, then rename it over `TODO.md`.
- **No lost updates:** every operation takes an exclusive lock (`TODO.md.lock`, created via an exclusive/`create-only` file open so two writers can't both get it) before it reads the file, and holds that lock until its write completes. A lock older than 5 seconds is assumed to be left by a crashed process and is cleared before retrying. **Re-reading before writing is not sufficient on its own** — two operations can each re-read a moment apart and still race to write; the lock is what actually serializes them. An implementation that skips the lock and only re-reads reopens the exact race story E1.3 exists to close.

---

## 4. Fixtures

```
spec/fixtures/
├── parse/<case>/input.md       file to read
├── parse/<case>/expected.json  what the parser must produce
├── write/<case>/input.md       starting file
├── write/<case>/ops.json       operations to run, in order
└── write/<case>/expected.md    exact bytes after writing
```

**Every parse case is also a round-trip test:** `serialize(parse(input.md))` must equal `input.md` byte for byte.

**`write/` is not built yet.** The shape above is the intended format (§4.2 describes it), but no fixtures exist under `write/` and neither `reference.py` nor the TypeScript tests run one — only `parse/` is exercised today. The two parsers' *writing* behavior is currently cross-checked only indirectly, through hand-written unit tests in each implementation (`mcp/src/__tests__/ops.test.ts` for TypeScript) that aren't guaranteed to cover the same cases on both sides. Building the `write/` fixtures and a runner for both languages is open work, not yet scheduled to a story.

### 4.1 `expected.json` shape

```json
{
  "lineEnding": "lf",
  "finalNewline": true,
  "bom": false,
  "headings": [
    { "line": 3, "raw": "## P0 — Now", "section": "P0" }
  ],
  "items": [
    {
      "line": 4,
      "section": "P0",
      "priority": "P0",
      "done": false,
      "title": "Reply to Enzo on Prismo pricing ruling",
      "id": "t_8f2a",
      "meta": { "due": "2026-09-27", "src": "claude-code" },
      "body": []
    }
  ]
}
```

- `line` numbers are 1-based, in the original file.
- `headings` lists level-2 headings only. `section` is `null` for unknown ones.
- `meta` holds every metadata key **except** `id`. Order doesn't matter when comparing.
- `body` holds the item's body lines **trimmed** of leading/trailing whitespace, without line endings. This is a read-view convenience for API/tool callers — the underlying document keeps each body line's exact original bytes (indentation included), and a line an operation doesn't touch is written back unchanged. Only this JSON view (and the API's matching `ItemView.body`) trims; §3 ("Writing the file") is byte-exact.

### 4.2 `ops.json` shape

```json
{
  "idSequence": ["t_0100", "t_0101"],
  "ops": [
    { "op": "add", "item": { "title": "…", "priority": "P1", "due": "2026-10-02", "added": "2026-09-26", "src": "claude-code" } },
    { "op": "complete", "id": "t_8f2a", "date": "2026-09-26" },
    { "op": "update", "id": "t_1c9d", "fields": { "priority": "P0" } },
    { "op": "assignMissingIds" }
  ]
}
```

New ids are taken from `idSequence` in order: first by `assignMissingIds` (items top to bottom), then by `add`. Implementations must let tests supply ids this way instead of generating random ones.

### 4.3 Running the checks

```bash
python3 spec/reference.py            # runs every fixture, prints PASS/FAIL
```
