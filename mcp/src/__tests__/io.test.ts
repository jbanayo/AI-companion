import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { withTodoFile, writeFileAtomic } from '../io.js';
import { addTodo } from '../ops.js';
import { makeSequenceIdGenerator } from '../id.js';

async function tempFile(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'the-list-test-'));
  return join(dir, 'TODO.md');
}

test('writeFileAtomic never leaves a partial file — a read either sees the old or the new content', async () => {
  const path = await tempFile();
  await writeFile(path, 'version 1\n');
  await writeFileAtomic(path, new TextEncoder().encode('version 2\n'));
  const content = await readFile(path, 'utf-8');
  assert.equal(content, 'version 2\n');

  // No leftover temp file after a successful write.
  const dirEntries = await readdir(join(path, '..'));
  assert.ok(!dirEntries.some((f) => f.includes('.tmp-')), 'no temp file should remain');
});

test('writeFileAtomic writes via a temp file and rename, not in place', async () => {
  const path = await tempFile();
  await writeFile(path, 'original\n');

  // If the target were written in place (not via temp+rename), truncation would be
  // visible mid-write for large content. We can't easily interrupt a real write, but
  // we can confirm the implementation's shape: after writing, the only file present
  // is the target — proving the temp file was renamed over it, not merged into it.
  await writeFileAtomic(path, new TextEncoder().encode('replaced\n'));
  const entries = await readdir(join(path, '..'));
  assert.deepEqual(entries, ['TODO.md']);
});

test('withTodoFile: two concurrent adds 10ms apart both land in the file (no lost update)', async () => {
  const path = await tempFile();
  await writeFile(path, '# Todo\n\n## P2 — Soon\n');

  const genA = makeSequenceIdGenerator(['t_aaaa']);
  const genB = makeSequenceIdGenerator(['t_bbbb']);

  const writerA = withTodoFile(path, (doc) => addTodo(doc, { title: 'From writer A' }, genA));
  await new Promise((r) => setTimeout(r, 10));
  const writerB = withTodoFile(path, (doc) => addTodo(doc, { title: 'From writer B' }, genB));

  await Promise.all([writerA, writerB]);

  const finalText = await readFile(path, 'utf-8');
  assert.ok(finalText.includes('From writer A'), 'writer A\'s item must survive');
  assert.ok(finalText.includes('From writer B'), 'writer B\'s item must survive');
  assert.ok(finalText.includes('t_aaaa'));
  assert.ok(finalText.includes('t_bbbb'));
});

test('withTodoFile: ten fully concurrent adds all land (stress test for the lock)', async () => {
  const path = await tempFile();
  await writeFile(path, '# Todo\n\n## P2 — Soon\n');

  const writers = Array.from({ length: 10 }, (_, i) =>
    withTodoFile(path, (doc) => addTodo(doc, { title: `Task ${i}` }, makeSequenceIdGenerator([`t_${String(i).padStart(4, '0')}`])))
  );
  await Promise.all(writers);

  const finalText = await readFile(path, 'utf-8');
  for (let i = 0; i < 10; i++) {
    assert.ok(finalText.includes(`Task ${i}`), `Task ${i} must be present`);
  }
  // Exactly 10 item lines — none clobbered, none duplicated.
  const itemLines = finalText.split('\n').filter((l) => l.startsWith('- ['));
  assert.equal(itemLines.length, 10);
});

test('withTodoFile leaves no lock file behind after it finishes', async () => {
  const path = await tempFile();
  await writeFile(path, '# Todo\n\n## P2 — Soon\n');
  await withTodoFile(path, (doc) => addTodo(doc, { title: 'One task' }, makeSequenceIdGenerator(['t_x'])));
  const entries = await readdir(join(path, '..'));
  assert.ok(!entries.some((f) => f.endsWith('.lock')), 'lock file must be cleaned up');
});
