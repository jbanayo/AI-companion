/** Types shared across the parser, renderer, and operations. Mirrors spec/format.md. */

export type LineEnding = 'lf' | 'crlf';
export type Priority = 'P0' | 'P1' | 'P2' | 'P3';
export type Section = Priority | 'Done';

/** The known metadata keys, in the canonical order §3.3 requires on render. */
export const KNOWN_KEYS = ['due', 'done', 'added', 'project', 'group', 'src', 'link', 'note'] as const;
export type KnownKey = (typeof KNOWN_KEYS)[number];

export interface ItemFields {
  title: string;
  id: string | null;
  /** Every metadata key except id, in original encounter order (for unknown-key passthrough). */
  meta: Map<string, string>;
  done: boolean;
}

/** One line that is a heading (`## P0 — Now`, or an unrecognized `## ...`). */
export interface HeadingNode {
  kind: 'heading';
  raw: string;
  /** null for an unrecognized heading (e.g. "## Ideas"). */
  section: Section | null;
}

/** One item line plus the body lines that belong to it. */
export interface ItemNode {
  kind: 'item';
  raw: string;
  touched: boolean;
  fields: ItemFields;
  /** Exact original text of each body line, indentation included. Never rewritten. */
  body: string[];
}

/** Anything else: blank lines, `# Todo`, prose, malformed items. Always passed through verbatim. */
export interface OtherNode {
  kind: 'other';
  raw: string;
}

export type Node = HeadingNode | ItemNode | OtherNode;

export interface Document {
  lineEnding: LineEnding;
  finalNewline: boolean;
  bom: boolean;
  nodes: Node[];
}

/** The read-only shape returned to API/tool callers — matches the parse fixtures' expected.json `items[]`. */
export interface ItemView {
  line: number;
  section: Section | null;
  priority: Section;
  done: boolean;
  title: string;
  id: string | null;
  meta: Record<string, string>;
  body: string[];
}

export interface HeadingView {
  line: number;
  raw: string;
  section: Section | null;
}

export const CANONICAL_HEADING: Record<Section, string> = {
  P0: '## P0 — Now',
  P1: '## P1 — This week',
  P2: '## P2 — Soon',
  P3: '## P3 — Someday',
  Done: '## Done',
};

/** Order sections are inserted in when a heading is missing (spec §3.4). */
export const SECTION_ORDER: Section[] = ['P0', 'P1', 'P2', 'P3', 'Done'];

export const EMPTY_SKELETON =
  '# Todo\n\n## P0 — Now\n\n## P1 — This week\n\n## P2 — Soon\n\n## P3 — Someday\n\n## Done\n';
