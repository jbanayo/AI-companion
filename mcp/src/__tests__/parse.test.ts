import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { parseDocument, deriveViews } from '../parse.js';
import { serialize } from '../serialize.js';

const fixturesDir = join(import.meta.dirname, '..', '..', '..', 'spec', 'fixtures', 'parse');

for (const name of readdirSync(fixturesDir).sort()) {
  const dir = join(fixturesDir, name);
  test(`parse fixture: ${name}`, () => {
    const raw = readFileSync(join(dir, 'input.md'));
    const expected = JSON.parse(readFileSync(join(dir, 'expected.json'), 'utf-8'));

    const doc = parseDocument(raw);
    const { headings, items } = deriveViews(doc);

    assert.equal(doc.lineEnding, expected.lineEnding);
    assert.equal(doc.finalNewline, expected.finalNewline);
    assert.equal(doc.bom, expected.bom);
    assert.deepEqual(headings, expected.headings);
    assert.deepEqual(items, expected.items);
  });

  test(`round-trip fixture: ${name}`, () => {
    const raw = readFileSync(join(dir, 'input.md'));
    const doc = parseDocument(raw);
    const out = serialize(doc);
    assert.ok(Buffer.compare(Buffer.from(out), raw) === 0, 'serialize(parse(x)) must equal x byte-for-byte');
  });
}
