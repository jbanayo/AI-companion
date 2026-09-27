import {
  CANONICAL_HEADING,
  Document,
  EMPTY_SKELETON,
  HeadingNode,
  ItemNode,
  Node,
  OtherNode,
  Section,
  SECTION_ORDER,
} from './model.js';
import { parseDocument } from './parse.js';
import { generateId } from './id.js';
import { today } from './priority.js';

/**
 * Strips newlines from a free-text field before it goes into the document.
 * A raw `\n` in a title or metadata value would split the rendered line in
 * two on write (render.ts only quotes a value, it doesn't escape newlines
 * inside it), corrupting the item on the very next read.
 */
function sanitizeText(s: string): string {
  return s.replace(/[\r\n]+/g, ' ').trim();
}

/** True when the document has no headings and no items — just blank/other lines, or nothing at all. */
export function isEffectivelyEmpty(doc: Document): boolean {
  return doc.nodes.every((n) => n.kind === 'other' && n.raw.trim() === '');
}

/** Spec §3.4 "Empty file": replace with the skeleton before inserting, and reset to lf/final-newline. */
export function ensureSkeleton(doc: Document): void {
  if (!isEffectivelyEmpty(doc)) return;
  const skeleton = parseDocument(new TextEncoder().encode(EMPTY_SKELETON));
  doc.nodes = skeleton.nodes;
  doc.lineEnding = 'lf';
  doc.finalNewline = true;
  doc.bom = false;
}

export interface AddInput {
  title: string;
  priority?: 'P0' | 'P1' | 'P2' | 'P3';
  due?: string;
  project?: string;
  src?: string;
  link?: string;
  note?: string;
  added?: string;
}

export interface UpdateFields {
  title?: string;
  priority?: 'P0' | 'P1' | 'P2' | 'P3';
  due?: string | null;
  project?: string | null;
  link?: string | null;
  note?: string | null;
}

function headingNode(section: Section): HeadingNode {
  return { kind: 'heading', raw: CANONICAL_HEADING[section], section };
}

function otherNode(raw: string): OtherNode {
  return { kind: 'other', raw };
}

function isBlankNode(node: Node | undefined): boolean {
  return !node || (node.kind === 'other' && node.raw.trim() === '');
}

/** Finds or creates the first heading for `section`. Returns its index and whether it was just created. */
function ensureSectionHeading(doc: Document, section: Section): { index: number; created: boolean; atEnd: boolean } {
  const existing = doc.nodes.findIndex((n) => n.kind === 'heading' && n.section === section);
  if (existing !== -1) return { index: existing, created: false, atEnd: false };

  const pos = SECTION_ORDER.indexOf(section);
  let insertBefore = -1;
  for (let p = pos + 1; p < SECTION_ORDER.length; p++) {
    const idx = doc.nodes.findIndex((n) => n.kind === 'heading' && n.section === SECTION_ORDER[p]);
    if (idx !== -1) {
      insertBefore = idx;
      break;
    }
  }

  if (insertBefore !== -1) {
    doc.nodes.splice(insertBefore, 0, headingNode(section));
    return { index: insertBefore, created: true, atEnd: false };
  }

  if (doc.nodes.length > 0 && !isBlankNode(doc.nodes[doc.nodes.length - 1])) {
    doc.nodes.push(otherNode(''));
  }
  const index = doc.nodes.length;
  doc.nodes.push(headingNode(section));
  return { index, created: true, atEnd: true };
}

/** Index just past the last item in `section`'s first run, or just past the heading if the run has no items. */
function endOfSectionRun(doc: Document, headingIndex: number): number {
  let insertAt = headingIndex + 1;
  for (let i = headingIndex + 1; i < doc.nodes.length; i++) {
    if (doc.nodes[i].kind === 'heading') break;
    if (doc.nodes[i].kind === 'item') insertAt = i + 1;
  }
  return insertAt;
}

function insertAt(doc: Document, section: Section, item: ItemNode, position: 'top' | 'end'): void {
  const { index, created, atEnd } = ensureSectionHeading(doc, section);
  const idx = position === 'top' ? index + 1 : endOfSectionRun(doc, index);
  doc.nodes.splice(idx, 0, item);
  if (created && !atEnd) {
    doc.nodes.splice(idx + 1, 0, otherNode(''));
  }
}

function findItemIndex(doc: Document, id: string): number {
  return doc.nodes.findIndex((n) => n.kind === 'item' && n.fields.id === id);
}

function collectIds(doc: Document): Set<string> {
  const used = new Set<string>();
  for (const node of doc.nodes) {
    if (node.kind === 'item' && node.fields.id !== null) used.add(node.fields.id);
  }
  return used;
}

/** Generates an id that doesn't collide with anything already in `used`, and reserves it. */
function uniqueId(used: Set<string>, idGen: () => string): string {
  let id = idGen();
  while (used.has(id)) id = idGen();
  used.add(id);
  return id;
}

/** Every operation runs this first (spec §3.2). Idempotent. */
export function assignMissingIds(doc: Document, idGen: () => string = generateId): void {
  const used = collectIds(doc);
  for (const node of doc.nodes) {
    if (node.kind === 'item' && node.fields.id === null) {
      node.fields.id = uniqueId(used, idGen);
      node.touched = true;
    }
  }
}

export function addTodo(doc: Document, input: AddInput, idGen: () => string = generateId): ItemNode {
  ensureSkeleton(doc);
  const priority: 'P0' | 'P1' | 'P2' | 'P3' = input.priority ?? 'P2';
  const meta = new Map<string, string>();
  if (input.due) meta.set('due', input.due);
  meta.set('added', input.added ?? today());
  if (input.project) meta.set('project', sanitizeText(input.project));
  meta.set('src', input.src ?? 'manual');
  if (input.link) meta.set('link', sanitizeText(input.link));
  if (input.note) meta.set('note', sanitizeText(input.note));

  const item: ItemNode = {
    kind: 'item',
    raw: '',
    touched: true,
    fields: { title: sanitizeText(input.title), id: uniqueId(collectIds(doc), idGen), meta, done: false },
    body: [],
  };

  insertAt(doc, priority, item, 'end');
  return item;
}

export function completeTodo(doc: Document, id: string, date: string): ItemNode | null {
  const idx = findItemIndex(doc, id);
  if (idx === -1) return null;
  const [item] = doc.nodes.splice(idx, 1) as [ItemNode];

  item.fields.done = true;
  item.fields.meta.set('done', date);
  item.touched = true;

  insertAt(doc, 'Done', item, 'top');
  return item;
}

export function reopenTodo(doc: Document, id: string, priority: 'P0' | 'P1' | 'P2' | 'P3' = 'P2'): ItemNode | null {
  const idx = findItemIndex(doc, id);
  if (idx === -1) return null;
  const [item] = doc.nodes.splice(idx, 1) as [ItemNode];

  item.fields.done = false;
  item.fields.meta.delete('done');
  item.touched = true;

  insertAt(doc, priority, item, 'end');
  return item;
}

export function updateTodo(doc: Document, id: string, fields: UpdateFields): ItemNode | null {
  const idx = findItemIndex(doc, id);
  if (idx === -1) return null;
  const item = doc.nodes[idx] as ItemNode;

  if (fields.title !== undefined) item.fields.title = sanitizeText(fields.title);
  for (const key of ['due', 'project', 'link', 'note'] as const) {
    const v = fields[key];
    if (v === null) item.fields.meta.delete(key);
    else if (v !== undefined) item.fields.meta.set(key, sanitizeText(v));
  }
  item.touched = true;

  if (fields.priority !== undefined) {
    // Determine current section from context, since ItemNode itself doesn't store it.
    const currentSection = currentSectionOf(doc, idx);
    if (fields.priority !== currentSection) {
      doc.nodes.splice(idx, 1);
      insertAt(doc, fields.priority, item, 'end');
    }
  }

  return item;
}

export function removeTodo(doc: Document, id: string): boolean {
  const idx = findItemIndex(doc, id);
  if (idx === -1) return false;
  doc.nodes.splice(idx, 1);
  return true;
}

function currentSectionOf(doc: Document, itemIndex: number): Section | null {
  for (let i = itemIndex; i >= 0; i--) {
    const n = doc.nodes[i];
    if (n.kind === 'heading') return n.section;
  }
  return null;
}

/** Simple normalized edit-distance similarity in [0,1]; 1 = identical. */
function similarity(a: string, b: string): number {
  const na = a.trim().toLowerCase().replace(/\s+/g, ' ');
  const nb = b.trim().toLowerCase().replace(/\s+/g, ' ');
  if (na === nb) return 1;
  const dist = levenshtein(na, nb);
  const maxLen = Math.max(na.length, nb.length) || 1;
  return 1 - dist / maxLen;
}

function levenshtein(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  const dp: number[] = Array(n + 1)
    .fill(0)
    .map((_, j) => j);
  for (let i = 1; i <= m; i++) {
    let prev = dp[0];
    dp[0] = i;
    for (let j = 1; j <= n; j++) {
      const tmp = dp[j];
      dp[j] = a[i - 1] === b[j - 1] ? prev : 1 + Math.min(prev, dp[j], dp[j - 1]);
      prev = tmp;
    }
  }
  return dp[n];
}

export const DUPLICATE_THRESHOLD = 0.82;

/** Fuzzy-matches `title` against open (not done) items. Returns the closest match at/above the threshold. */
export function findSimilarOpenItem(doc: Document, title: string): ItemNode | null {
  let best: ItemNode | null = null;
  let bestScore = 0;
  for (const node of doc.nodes) {
    if (node.kind !== 'item' || node.fields.done) continue;
    const score = similarity(node.fields.title, title);
    if (score >= DUPLICATE_THRESHOLD && score > bestScore) {
      best = node;
      bestScore = score;
    }
  }
  return best;
}
