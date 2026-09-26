#!/usr/bin/env python3
"""
Reference parser for TODO.md format (spec/format.md).

Validates all fixtures in spec/fixtures/parse/ and spec/fixtures/write/.
Usage:
  python3 spec/reference.py               # run all checks
  python3 spec/reference.py parse/normal  # run one case
"""

import json
import re
import sys
from pathlib import Path
from dataclasses import dataclass, asdict, field
from typing import Optional

# ============================================================================
# Data model
# ============================================================================

@dataclass
class ParseResult:
    lineEnding: str  # "lf" or "crlf"
    finalNewline: bool
    bom: bool
    headings: list = field(default_factory=list)
    items: list = field(default_factory=list)

@dataclass
class HeadingInfo:
    line: int
    raw: str
    section: Optional[str]

@dataclass
class ItemInfo:
    line: int
    section: Optional[str]
    priority: str  # P0, P1, P2, P3, Done, or P2 (default)
    done: bool
    title: str
    id: Optional[str]
    meta: dict = field(default_factory=dict)
    body: list = field(default_factory=list)

# ============================================================================
# Parser
# ============================================================================

class TodoParser:
    def __init__(self, raw_bytes: bytes):
        self.raw_bytes = raw_bytes
        self.text = raw_bytes.decode('utf-8')
        self.bom = self.text.startswith('﻿')
        if self.bom:
            self.text = self.text[1:]
        self._detect_line_ending()
        self.lines = self._split_lines()
        self.result = ParseResult(
            lineEnding=self.line_ending,
            finalNewline=self.has_final_newline,
            bom=self.bom
        )
        self._parse()

    def _detect_line_ending(self):
        """Detect line ending from first line."""
        if '\r\n' in self.text[:200]:
            self.line_ending = 'crlf'
            self.has_final_newline = self.text.endswith('\r\n') or self.text.endswith('\n')
        else:
            self.line_ending = 'lf'
            self.has_final_newline = self.text.endswith('\n') if self.text else False

    def _split_lines(self) -> list:
        """Split text into lines, removing line endings."""
        if not self.text:
            return []
        lines = self.text.split('\n')
        # Remove trailing \r from each line
        lines = [line.rstrip('\r') for line in lines]
        # Remove empty last line if it exists (from final newline)
        if lines and lines[-1] == '':
            lines.pop()
        return lines

    def _is_heading(self, line: str) -> tuple:
        """Check if line is a level-2 heading. Return (is_heading, section_key) where section_key is None for unknown headings."""
        if not line.startswith('## '):
            return (False, None)
        rest = line[3:]
        match = re.match(r'^(P0|P1|P2|P3|Done|p0|p1|p2|p3|done)\b', rest, re.IGNORECASE)
        if match:
            key = match.group(1).upper()
            if key == 'DONE':
                return (True, 'Done')
            return (True, key)
        # Unknown heading - still a heading
        return (True, None)

    def _is_item(self, line: str) -> Optional[tuple]:
        """Check if line is an item. Return (checkbox, content) or None."""
        match = re.match(r'^[-*+][ \t]+\[( |x|X)\][ \t]+(.+)$', line)
        if not match:
            return None
        checkbox, content = match.groups()
        return (checkbox, content)

    def _parse_metadata(self, content: str) -> tuple:
        """Extract metadata block from content. Return (title, metadata_dict)."""
        # The block must be at the end, preceded by whitespace
        stripped = content.rstrip()

        # Find last }
        last_brace = stripped.rfind('}')
        if last_brace == -1 or last_brace == len(stripped) - 1:
            # No closing brace, or it's at the very end (which is required)
            pass

        if last_brace == -1:
            return (content.strip(), {})

        # Check: if the content before } is "stripped", then last_brace is at its end
        if last_brace < len(stripped) - 1:
            # Something after }, so not a valid block suffix
            return (content.strip(), {})

        # Find the opening {, but only the one that would make a valid block
        # Valid block: { <pairs> } where each pair is key:value
        brace_depth = 0
        open_brace = -1
        for i in range(last_brace, -1, -1):
            if stripped[i] == '}':
                brace_depth += 1
            elif stripped[i] == '{':
                brace_depth -= 1
                if brace_depth == 0:
                    open_brace = i
                    break

        if open_brace == -1 or open_brace == 0:
            return (content.strip(), {})

        # Check for space or tab before {
        if stripped[open_brace - 1] not in (' ', '\t'):
            return (content.strip(), {})

        # Try to parse the block
        block_str = stripped[open_brace + 1:last_brace]
        title = stripped[:open_brace].rstrip()

        if not title:
            return (content.strip(), {})

        # Parse pairs
        meta = {}
        try:
            meta = self._parse_block(block_str)
        except:
            # If parsing fails, treat whole thing as title
            return (content.strip(), {})

        return (title, meta)

    def _parse_block(self, block_str: str) -> dict:
        """Parse key:value pairs from block string."""
        meta = {}
        i = 0
        n = len(block_str)

        while i < n:
            # Skip whitespace
            while i < n and block_str[i] in ' \t':
                i += 1
            if i >= n:
                break

            # Parse key: [a-z][a-z0-9_]*
            key_start = i
            if i < n and block_str[i] not in 'abcdefghijklmnopqrstuvwxyz':
                break
            i += 1
            while i < n and block_str[i] in 'abcdefghijklmnopqrstuvwxyz0123456789_':
                i += 1
            key = block_str[key_start:i]

            # Expect :
            while i < n and block_str[i] in ' \t':
                i += 1
            if i >= n or block_str[i] != ':':
                break
            i += 1

            # Skip whitespace after :
            while i < n and block_str[i] in ' \t':
                i += 1

            # Parse value: quoted or bare
            value = ''
            if i < n and block_str[i] == '"':
                # Quoted: "..." with \" and \\ escapes
                i += 1
                while i < n:
                    if block_str[i] == '\\' and i + 1 < n:
                        next_ch = block_str[i + 1]
                        if next_ch == '"':
                            value += '"'
                            i += 2
                        elif next_ch == '\\':
                            value += '\\'
                            i += 2
                        else:
                            value += block_str[i]
                            i += 1
                    elif block_str[i] == '"':
                        i += 1
                        break
                    else:
                        value += block_str[i]
                        i += 1
            else:
                # Bare: anything except whitespace, {, }, "
                value_start = i
                while i < n and block_str[i] not in ' \t{}\"':
                    i += 1
                value = block_str[value_start:i]

            meta[key] = value

        return meta

    def _parse(self):
        """Main parse loop."""
        current_section = None
        current_item = None
        seen_ids = {}

        for line_num, line in enumerate(self.lines, 1):
            # Check for heading
            is_heading, section = self._is_heading(line)
            if is_heading:
                current_section = section
                self.result.headings.append(HeadingInfo(
                    line=line_num,
                    raw=line,
                    section=section
                ))
                current_item = None
                continue

            # Check for item
            item_match = self._is_item(line)
            if item_match is not None:
                checkbox, content = item_match
                title, meta = self._parse_metadata(content)

                if not title:
                    # Empty title - not an item
                    current_item = None
                    continue

                done = checkbox in ('x', 'X')
                priority = self._get_priority(current_section, done)
                item_id = meta.pop('id', None)

                # Check for duplicate id
                if item_id and item_id in seen_ids:
                    item_id = None
                elif item_id:
                    seen_ids[item_id] = True

                item = ItemInfo(
                    line=line_num,
                    section=current_section,
                    priority=priority,
                    done=done,
                    title=title,
                    id=item_id,
                    meta=meta,
                    body=[]
                )
                self.result.items.append(item)
                current_item = item
                continue

            # Check for body line (must follow an item)
            if current_item is not None and line.startswith((' ', '\t')) and line.strip():
                current_item.body.append(line.strip())
                continue

            # Blank line ends current item
            if line.strip() == '':
                current_item = None
                continue

            # Other line
            current_item = None

    def _get_priority(self, section: Optional[str], done: bool) -> str:
        """Get priority for an item."""
        if section in ('P0', 'P1', 'P2', 'P3'):
            return section
        if section == 'Done':
            return 'Done'
        return 'P2'  # default

# ============================================================================
# Test runner
# ============================================================================

def load_json(path: Path) -> dict:
    """Load and parse JSON."""
    return json.loads(path.read_text())

def test_parse(case_dir: Path) -> bool:
    """Test a single parse case."""
    input_file = case_dir / "input.md"
    expected_file = case_dir / "expected.json"

    if not input_file.exists() or not expected_file.exists():
        return None

    raw = input_file.read_bytes()
    parser = TodoParser(raw)

    actual = {
        'lineEnding': parser.result.lineEnding,
        'finalNewline': parser.result.finalNewline,
        'bom': parser.result.bom,
        'headings': [asdict(h) for h in parser.result.headings],
        'items': [asdict(i) for i in parser.result.items]
    }

    expected = load_json(expected_file)

    if actual != expected:
        print(f"  {case_dir.name}: FAIL")
        # Show first difference
        for key in ['lineEnding', 'finalNewline', 'bom']:
            if actual[key] != expected[key]:
                print(f"    {key}: {actual[key]} vs {expected[key]}")
        if len(actual['headings']) != len(expected['headings']):
            print(f"    headings: {len(actual['headings'])} vs {len(expected['headings'])}")
        else:
            for i, (a, e) in enumerate(zip(actual['headings'], expected['headings'])):
                if a != e:
                    print(f"    headings[{i}]: {a} vs {e}")
        if len(actual['items']) != len(expected['items']):
            print(f"    items: {len(actual['items'])} vs {len(expected['items'])}")
        else:
            for i, (a, e) in enumerate(zip(actual['items'], expected['items'])):
                if a != e:
                    print(f"    items[{i}]: {a}")
                    print(f"             vs {e}")
        return False

    print(f"  {case_dir.name}: PASS")
    return True

def main():
    root = Path(__file__).parent
    fixtures_dir = root / "fixtures" / "parse"

    if len(sys.argv) > 1:
        case_name = sys.argv[1]
        if case_name.startswith("parse/"):
            case_name = case_name[6:]
        case_path = fixtures_dir / case_name
        if not case_path.exists():
            print(f"Case not found: {case_path}")
            sys.exit(1)
        result = test_parse(case_path)
        sys.exit(0 if result else 1)

    if not fixtures_dir.exists():
        print(f"No fixtures in {fixtures_dir}")
        sys.exit(1)

    cases = sorted([d for d in fixtures_dir.iterdir() if d.is_dir()])
    passed = 0
    failed = 0

    print("Parse fixtures:")
    for case_dir in cases:
        result = test_parse(case_dir)
        if result:
            passed += 1
        elif result is False:
            failed += 1

    print(f"\nTotal: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
