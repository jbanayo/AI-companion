import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readSettings } from '../settings.js';
import { effectiveGroup } from '../groups.js';
import { ItemView } from '../model.js';

async function tempSettingsPath(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'the-list-settings-test-'));
  return join(dir, 'settings.json');
}

test('missing file defaults to proactive: true', async () => {
  const path = await tempSettingsPath(); // never written
  assert.deepEqual(await readSettings(path), { proactive: true, groups: [] });
});

test('reads proactive: false from a valid file', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, JSON.stringify({ proactive: false, groups: [] }));
  assert.deepEqual(await readSettings(path), { proactive: false, groups: [] });
});

test('malformed JSON falls back to the default rather than throwing', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, '{ not valid json');
  assert.deepEqual(await readSettings(path), { proactive: true, groups: [] });
});

test('a file missing the proactive key falls back to the default', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, JSON.stringify({ somethingElse: 1 }));
  assert.deepEqual(await readSettings(path), { proactive: true, groups: [] });
});

test('groups: keeps well-formed entries, drops bad ones and duplicate ids, defaults name to id', async () => {
  const path = await tempSettingsPath();
  await writeFile(
    path,
    JSON.stringify({
      groups: [
        { id: 'byc', name: 'BYC', projects: ['solomon', 3, 'lumen'] },
        { name: 'no id' },
        'not an object',
        { id: 'BYC', name: 'duplicate' },
        { id: 'home' },
      ],
    })
  );
  assert.deepEqual(await readSettings(path), {
    proactive: true,
    groups: [
      { id: 'byc', name: 'BYC', projects: ['solomon', 'lumen'] },
      { id: 'home', name: 'home', projects: [] },
    ],
  });
});

test('groups: a non-array value means no groups', async () => {
  const path = await tempSettingsPath();
  await writeFile(path, JSON.stringify({ proactive: false, groups: { byc: true } }));
  assert.deepEqual(await readSettings(path), { proactive: false, groups: [] });
});

function view(meta: Record<string, string>): ItemView {
  return { line: 1, section: 'P2', priority: 'P2', done: false, title: 't', id: 't_0001', meta, body: [] };
}

test('effectiveGroup: explicit key, then project, then none; case-insensitive', () => {
  const groups = [
    { id: 'byc', name: 'BYC', projects: ['Solomon'] },
    { id: 'personal', name: 'Personal', projects: ['personal'] },
  ];
  assert.equal(effectiveGroup(view({ group: 'PERSONAL', project: 'solomon' }), groups)?.id, 'personal');
  assert.equal(effectiveGroup(view({ project: 'SOLOMON' }), groups)?.id, 'byc');
  // An unknown group key falls back to the project's group.
  assert.equal(effectiveGroup(view({ group: 'gone', project: 'solomon' }), groups)?.id, 'byc');
  assert.equal(effectiveGroup(view({ group: 'gone' }), groups), undefined);
  assert.equal(effectiveGroup(view({}), groups), undefined);
  assert.equal(effectiveGroup(view({ project: 'solomon' }), []), undefined);
});
