import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readSettings } from '../settings.js';

async function tempSettingsPath(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'the-list-settings-test-'));
  return join(dir, 'settings.json');
}

test('missing file defaults to proactive: true', async () => {
  const path = await tempSettingsPath(); // never written
  assert.deepEqual(await readSettings(path), { proactive: true });
});

test('reads proactive: false from a valid file', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, JSON.stringify({ proactive: false }));
  assert.deepEqual(await readSettings(path), { proactive: false });
});

test('malformed JSON falls back to the default rather than throwing', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, '{ not valid json');
  assert.deepEqual(await readSettings(path), { proactive: true });
});

test('a file missing the proactive key falls back to the default', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, JSON.stringify({ somethingElse: 1 }));
  assert.deepEqual(await readSettings(path), { proactive: true });
});
