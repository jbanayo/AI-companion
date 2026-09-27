import {
  Document,
  HeadingNode,
  HeadingView,
  ItemNode,
  ItemView,
  LineEnding,
  Node,
  OtherNode,
  Section,
} from './model.js';

const HEADING_RE = /^(P0|P1|P2|P3|Done)\b/i;
const ITEM_RE = /^[-*+][ \t]+\[( |x|X)\][ \t]+(.+)$/;

function normalizeSection(raw: string): Section {
  const upper = raw.toUpperCase();
  return upper === 'DONE' ? 'Done' : (upper as Section);
}

function isHeading(line: string): { section: Section | null } | null {
  if (!line.startsWith('## ')) return null;
  const rest = line.slice(3);
  const match = rest.match(HEADING_RE);
  return { section: match ? normalizeSection(match[1]) : null };
}

function isItem(line: string): { checkbox: string; content: string } | null {
  const match = line.match(ITEM_RE);
  if (!match) return null;
  return { checkbox: match[1], content: match[2] };
}

/**
 * Splits an item's content into title + metadata block, per spec §2.5.
 * The block is the *shortest* trailing `{...}` preceded by whitespace that
 * parses fully as `key:value` pairs. Anything that doesn't parse as a full
 * block is left in the title untouched.
 *
 * Candidate open braces are tried from rightmost (shortest suffix) to
 * leftmost, each validated by actually running the pair grammar rather than
 * by counting brace depth — depth-counting breaks as soon as a quoted value
 * contains an unbalanced `{` or `}` (e.g. `note:"the { is missing"`), since
 * it can't tell a quoted literal brace from a real nesting boundary.
 */
function parseMetadata(content: string): { title: string; meta: Map<string, string> } {
  const stripped = content.replace(/[ \t]+$/, '');
  if (!stripped.endsWith('}')) return { title: content.trim(), meta: new Map() };

  const candidates: number[] = [];
  for (let i = 1; i < stripped.length; i++) {
    if (stripped[i] === '{' && (stripped[i - 1] === ' ' || stripped[i - 1] === '\t')) candidates.push(i);
  }

  for (let k = candidates.length - 1; k >= 0; k--) {
    const openBrace = candidates[k];
    const blockStr = stripped.slice(openBrace + 1, stripped.length - 1);
    const meta = parseBlock(blockStr);
    if (meta === null) continue;
    const title = stripped.slice(0, openBrace).replace(/[ \t]+$/, '');
    if (!title) break; // degenerate: nothing left for a title, treat as no block
    return { title, meta };
  }

  return { title: content.trim(), meta: new Map() };
}

/** Returns null if the block content doesn't fully parse as `pair (ws+ pair)*`. */
function parseBlock(block: string): Map<string, string> | null {
  const meta = new Map<string, string>();
  let i = 0;
  const n = block.length;

  while (i < n) {
    while (i < n && (block[i] === ' ' || block[i] === '\t')) i++;
    if (i >= n) break;

    const keyStart = i;
    if (!/[a-z]/.test(block[i])) return null;
    i++;
    while (i < n && /[a-z0-9_]/.test(block[i])) i++;
    const key = block.slice(keyStart, i);

    while (i < n && (block[i] === ' ' || block[i] === '\t')) i++;
    if (i >= n || block[i] !== ':') return null;
    i++;
    while (i < n && (block[i] === ' ' || block[i] === '\t')) i++;

    let value = '';
    if (i < n && block[i] === '"') {
      i++;
      let closed = false;
      while (i < n) {
        if (block[i] === '\\' && i + 1 < n && (block[i + 1] === '"' || block[i + 1] === '\\')) {
          value += block[i + 1];
          i += 2;
        } else if (block[i] === '"') {
          i++;
          closed = true;
          break;
        } else {
          value += block[i];
          i++;
        }
      }
      if (!closed) return null;
    } else {
      const valStart = i;
      while (i < n && !/[ \t{}"]/.test(block[i])) i++;
      if (i === valStart) return null; // empty bare value is not valid
      value = block.slice(valStart, i);
    }

    meta.set(key, value); // last one wins on duplicate keys
  }

  return meta;
}

export function parseDocument(raw: Uint8Array): Document {
  let text = new TextDecoder('utf-8').decode(raw);
  const bom = text.startsWith('﻿');
  if (bom) text = text.slice(1);

  const lineEnding: LineEnding = text.includes('\r\n') ? 'crlf' : 'lf';
  const finalNewline = lineEnding === 'crlf' ? /\r\n$/.test(text) : text.endsWith('\n') && !text.endsWith('\r\n') ? true : /\n$/.test(text);

  let rawLines = text.length === 0 ? [] : text.split('\n').map((l) => l.replace(/\r$/, ''));
  if (rawLines.length > 0 && rawLines[rawLines.length - 1] === '') rawLines.pop();

  const nodes: Node[] = [];
  const seenIds = new Set<string>();
  let currentItem: ItemNode | null = null;

  for (const line of rawLines) {
    const heading = isHeading(line);
    if (heading) {
      nodes.push({ kind: 'heading', raw: line, section: heading.section } satisfies HeadingNode);
      currentItem = null;
      continue;
    }

    const item = isItem(line);
    if (item) {
      const { title, meta } = parseMetadata(item.content);
      if (!title) {
        nodes.push({ kind: 'other', raw: line } satisfies OtherNode);
        currentItem = null;
        continue;
      }
      const done = item.checkbox === 'x' || item.checkbox === 'X';
      let id = meta.get('id') ?? null;
      meta.delete('id');
      if (id !== null) {
        if (seenIds.has(id)) id = null;
        else seenIds.add(id);
      }
      const node: ItemNode = {
        kind: 'item',
        raw: line,
        touched: false,
        fields: { title, id, meta, done },
        body: [],
      };
      nodes.push(node);
      currentItem = node;
      continue;
    }

    if (currentItem && /^[ \t]/.test(line) && line.trim() !== '') {
      currentItem.body.push(line);
      continue;
    }

    // Any line that isn't a body candidate for currentItem — blank or not —
    // breaks the "directly after" chain (spec §2.2), so a later indented
    // line must not attach to this item as a body line.
    nodes.push({ kind: 'other', raw: line } satisfies OtherNode);
    currentItem = null;
  }

  return { lineEnding, finalNewline, bom, nodes };
}

function effectivePriority(section: Section | null, done: boolean): Section {
  if (section === 'P0' || section === 'P1' || section === 'P2' || section === 'P3') return section;
  if (section === 'Done') return 'Done';
  return 'P2';
}

/** Derives the read-only item/heading views (matches spec/fixtures expected.json shape). */
export function deriveViews(doc: Document): { headings: HeadingView[]; items: ItemView[] } {
  const headings: HeadingView[] = [];
  const items: ItemView[] = [];
  let currentSection: Section | null = null;
  let lineNo = 0;

  for (const node of doc.nodes) {
    lineNo += 1;
    if (node.kind === 'heading') {
      currentSection = node.section;
      headings.push({ line: lineNo, raw: node.raw, section: node.section });
    } else if (node.kind === 'item') {
      const meta: Record<string, string> = {};
      for (const [k, v] of node.fields.meta) meta[k] = v;
      items.push({
        line: lineNo,
        section: currentSection,
        priority: effectivePriority(currentSection, node.fields.done),
        done: node.fields.done,
        title: node.fields.title,
        id: node.fields.id,
        meta,
        body: node.body.map((b) => b.trim()),
      });
      lineNo += node.body.length;
    }
  }

  return { headings, items };
}
