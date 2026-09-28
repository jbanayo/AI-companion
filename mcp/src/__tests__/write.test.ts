/**
 * Runs spec/fixtures/write/: apply ops.json to input.md, compare to expected.md byte for byte.
 * THE_LIST_GENERATE=1 writes expected.md instead of comparing — review every generated file by hand.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseDocument } from '../parse.js';
import { serialize } from '../serialize.js';
import { addTodo, assignMissingIds, completeTodo, removeTodo, reopenTodo, updateTodo } from '../ops.js';

const fixturesDir = join(import.meta.dirname, '..', '..', '..', 'spec', 'fixtures', 'write');
const generate = process.env.THE_LIST_GENERATE === '1';

function strictSequence(ids: string[]): () => string {
  let i = 0;
  return () => {
    if (i >= ids.length) throw new Error('idSequence exhausted — the fixture needs more ids');
    return ids[i++];
  };
}

for (const name of readdirSync(fixturesDir).sort()) {
  const dir = join(fixturesDir, name);
  test(`write fixture: ${name}`, () => {
    const input = readFileSync(join(dir, 'input.md'));
    const { idSequence, ops } = JSON.parse(readFileSync(join(dir, 'ops.json'), 'utf-8'));
    const nextId = strictSequence(idSequence);
    const doc = parseDocument(input);

    for (const op of ops) {
      assignMissingIds(doc, nextId); // spec §3.2: every operation runs this first
      switch (op.op) {
        case 'assignMissingIds':
          break;
        case 'add':
          addTodo(doc, op.item, nextId);
          break;
        case 'complete':
          assert.ok(completeTodo(doc, op.id, op.date), `complete: no item ${op.id}`);
          break;
        case 'reopen':
          assert.ok(reopenTodo(doc, op.id, op.priority), `reopen: no item ${op.id}`);
          break;
        case 'update':
          assert.ok(updateTodo(doc, op.id, op.fields), `update: no item ${op.id}`);
          break;
        case 'remove':
          assert.ok(removeTodo(doc, op.id), `remove: no item ${op.id}`);
          break;
        default:
          throw new Error(`unknown op: ${op.op}`);
      }
    }

    const out = Buffer.from(serialize(doc));
    if (generate) {
      writeFileSync(join(dir, 'expected.md'), out);
      return;
    }
    const expected = readFileSync(join(dir, 'expected.md'));
    assert.equal(out.toString('utf-8'), expected.toString('utf-8'));
    assert.ok(Buffer.compare(out, expected) === 0, 'bytes must match exactly');
  });
}
