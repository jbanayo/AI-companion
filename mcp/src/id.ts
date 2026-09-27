import { randomBytes } from 'node:crypto';

/** t_ + 4 lowercase hex chars, e.g. t_8f2a. Injectable for tests (spec §4.2 idSequence). */
export function generateId(): string {
  return `t_${randomBytes(2).toString('hex')}`;
}

/** Returns ids from a fixed list in order, then falls back to generateId(). Used by tests only. */
export function makeSequenceIdGenerator(ids: string[]): () => string {
  let i = 0;
  return () => (i < ids.length ? ids[i++] : generateId());
}
