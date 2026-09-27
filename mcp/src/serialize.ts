import { Document } from './model.js';
import { renderItemLine } from './render.js';

/**
 * Reconstructs the file bytes from a Document. Untouched nodes are emitted
 * byte-for-byte from their `raw` text; only `touched` item lines are
 * re-rendered. Body lines are never rewritten (spec §3.3/§3.1).
 */
export function serialize(doc: Document): Uint8Array {
  const eol = doc.lineEnding === 'crlf' ? '\r\n' : '\n';
  const lines: string[] = [];

  for (const node of doc.nodes) {
    if (node.kind === 'heading' || node.kind === 'other') {
      lines.push(node.raw);
    } else {
      lines.push(node.touched ? renderItemLine(node.fields) : node.raw);
      lines.push(...node.body);
    }
  }

  let text = lines.join(eol);
  if (doc.finalNewline && lines.length > 0) text += eol;
  if (doc.bom) text = '﻿' + text;

  return new TextEncoder().encode(text);
}
