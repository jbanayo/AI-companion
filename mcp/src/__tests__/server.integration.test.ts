/**
 * End-to-end test: spawns the real built server (dist/index.js) as a child
 * process over stdio, exactly the way Claude Code / Claude Desktop will,
 * and drives it through the MCP client SDK. Requires `npm run build` first
 * (the test script does this).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const serverEntry = join(import.meta.dirname, '..', '..', 'dist', 'index.js');

async function connectClient(dataDir: string, src = 'claude-code') {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    env: { THE_LIST_DATA_DIR: dataDir, THE_LIST_SRC: src },
  });
  const client = new Client({ name: 'test-client', version: '0.0.0' });
  await client.connect(transport);
  return client;
}

async function tempDataDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), 'the-list-server-test-'));
}

test('lists the four tools with descriptions', async () => {
  const dir = await tempDataDir();
  const client = await connectClient(dir);
  try {
    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name).sort();
    assert.deepEqual(names, ['add_todo', 'complete_todo', 'get_settings', 'list_todos', 'update_todo']);
    for (const t of tools) assert.ok(t.description && t.description.length > 10, `${t.name} needs a real description`);
  } finally {
    await client.close();
  }
});

test('add_todo -> list_todos -> complete_todo -> update_todo end to end', async () => {
  const dir = await tempDataDir();
  const client = await connectClient(dir, 'claude-code');
  try {
    const added = await client.callTool({
      name: 'add_todo',
      arguments: { title: 'Reply to Enzo on Prismo pricing', priority: 'P1', due: '2026-09-27', project: 'prismo' },
    });
    const addedContent = added.structuredContent as any;
    assert.equal(addedContent.added, true);
    assert.equal(addedContent.duplicate, false);
    assert.equal(addedContent.item.priority, 'P0'); // due today -> displays as P0
    const id = addedContent.item.id as string;
    assert.match(id, /^t_[0-9a-f]{4}$/);

    // The file on disk was actually written, with the right src.
    const fileText = await readFile(join(dir, 'TODO.md'), 'utf-8');
    assert.match(fileText, /src:claude-code/);
    assert.match(fileText, /project:prismo/);

    const listed = await client.callTool({ name: 'list_todos', arguments: {} });
    const listedContent = listed.structuredContent as any;
    assert.equal(listedContent.count, 1);
    assert.equal(listedContent.items[0].id, id);

    const dup = await client.callTool({
      name: 'add_todo',
      arguments: { title: 'reply to enzo on prismo pricing' }, // near-duplicate, different case
    });
    const dupContent = dup.structuredContent as any;
    assert.equal(dupContent.duplicate, true);
    assert.equal(dupContent.item.id, id);

    const updated = await client.callTool({
      name: 'update_todo',
      arguments: { id, note: 'waiting on his reply' },
    });
    assert.equal((updated.structuredContent as any).item.note, 'waiting on his reply');

    const completed = await client.callTool({ name: 'complete_todo', arguments: { id } });
    assert.equal((completed.structuredContent as any).completed, true);

    const openList = await client.callTool({ name: 'list_todos', arguments: { status: 'open' } });
    assert.equal((openList.structuredContent as any).count, 0);

    const doneList = await client.callTool({ name: 'list_todos', arguments: { status: 'done' } });
    assert.equal((doneList.structuredContent as any).count, 1);
  } finally {
    await client.close();
  }
});

test('add_todo with allowDuplicate: true adds a near-duplicate title instead of blocking it', async () => {
  const dir = await tempDataDir();
  const client = await connectClient(dir);
  try {
    await client.callTool({ name: 'add_todo', arguments: { title: 'Review Solomon extract PR #41' } });

    const blocked = await client.callTool({ name: 'add_todo', arguments: { title: 'Review Solomon extract PR #42' } });
    assert.equal((blocked.structuredContent as any).duplicate, true);

    const forced = await client.callTool({
      name: 'add_todo',
      arguments: { title: 'Review Solomon extract PR #42', allowDuplicate: true },
    });
    const forcedContent = forced.structuredContent as any;
    assert.equal(forcedContent.added, true);
    assert.equal(forcedContent.duplicate, false);

    const listed = await client.callTool({ name: 'list_todos', arguments: {} });
    assert.equal((listed.structuredContent as any).count, 2);
  } finally {
    await client.close();
  }
});

test('items added via a claude-desktop-configured server are tagged src:claude-desktop', async () => {
  const dir = await tempDataDir();
  const client = await connectClient(dir, 'claude-desktop');
  try {
    await client.callTool({ name: 'add_todo', arguments: { title: 'Desktop-originated task' } });
    const fileText = await readFile(join(dir, 'TODO.md'), 'utf-8');
    assert.match(fileText, /src:claude-desktop/);
  } finally {
    await client.close();
  }
});

test('get_settings reflects data/settings.json, defaulting to proactive: true when absent', async () => {
  const dir = await tempDataDir();
  const client = await connectClient(dir);
  try {
    const missing = await client.callTool({ name: 'get_settings', arguments: {} });
    assert.deepEqual(missing.structuredContent, { proactive: true });

    await writeFile(join(dir, 'settings.json'), JSON.stringify({ proactive: false }));
    const off = await client.callTool({ name: 'get_settings', arguments: {} });
    assert.deepEqual(off.structuredContent, { proactive: false });
  } finally {
    await client.close();
  }
});

test('a hand-edited file with no id gets one assigned as soon as it is listed', async () => {
  const dir = await tempDataDir();
  await writeFile(join(dir, 'TODO.md'), '# Todo\n\n## P2 — Soon\n- [ ] Hand-typed task\n');
  const client = await connectClient(dir);
  try {
    // list_todos is a query, but a listed item still needs a real id to be actionable in
    // complete_todo/update_todo afterwards — so it self-heals missing ids as it reads.
    const result = await client.callTool({ name: 'list_todos', arguments: {} });
    const items = (result.structuredContent as any).items;
    assert.equal(items.length, 1);
    assert.match(items[0].id, /^t_[0-9a-f]{4}$/);

    const fileText = await readFile(join(dir, 'TODO.md'), 'utf-8');
    assert.match(fileText, new RegExp(`Hand-typed task \\{id:${items[0].id}\\}`));

    // And that id is now usable by the other tools.
    const completed = await client.callTool({ name: 'complete_todo', arguments: { id: items[0].id } });
    assert.equal((completed.structuredContent as any).completed, true);
  } finally {
    await client.close();
  }
});
