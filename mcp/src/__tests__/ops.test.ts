import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseDocument, deriveViews } from '../parse.js';
import { serialize } from '../serialize.js';
import {
  addTodo,
  assignMissingIds,
  completeTodo,
  findSimilarOpenItem,
  removeTodo,
  reopenTodo,
  updateTodo,
} from '../ops.js';
import { makeSequenceIdGenerator } from '../id.js';
import { today } from '../priority.js';

function docFrom(text: string) {
  return parseDocument(new TextEncoder().encode(text));
}

function textOf(doc: ReturnType<typeof docFrom>) {
  return new TextDecoder().decode(serialize(doc));
}

test('addTodo into an existing section with items appends after the last one', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] First {id:t_0001}\n\n## P2 — Soon\n');
  const gen = makeSequenceIdGenerator(['t_new1']);
  addTodo(doc, { title: 'Second', priority: 'P1' }, gen);
  const out = textOf(doc);
  assert.equal(
    out,
    '# Todo\n\n## P1 — This week\n- [ ] First {id:t_0001}\n- [ ] Second {id:t_new1 added:' +
      today() +
      ' src:manual}\n\n## P2 — Soon\n'
  );
});

test('addTodo creates a missing heading in canonical order, with a trailing blank line', () => {
  // A hand-edited file that never had a P1 section.
  const doc = docFrom('# Todo\n\n## P0 — Now\n\n## P2 — Soon\n\n## P3 — Someday\n\n## Done\n');
  const gen = makeSequenceIdGenerator(['t_aaaa']);
  addTodo(doc, { title: 'Needs P1', priority: 'P1', added: '2026-09-27' }, gen);
  const out = textOf(doc);
  assert.equal(
    out,
    '# Todo\n\n## P0 — Now\n\n## P1 — This week\n- [ ] Needs P1 {id:t_aaaa added:2026-09-27 src:manual}\n\n## P2 — Soon\n\n## P3 — Someday\n\n## Done\n'
  );
});

test('addTodo appends a brand-new heading at end of file when no later section exists', () => {
  const doc = docFrom('# Todo\n\n## P0 — Now\n- [ ] Only item {id:t_0001}\n');
  const gen = makeSequenceIdGenerator(['t_p3']);
  addTodo(doc, { title: 'Someday idea', priority: 'P3', added: '2026-09-27' }, gen);
  const out = textOf(doc);
  assert.equal(
    out,
    '# Todo\n\n## P0 — Now\n- [ ] Only item {id:t_0001}\n\n## P3 — Someday\n- [ ] Someday idea {id:t_p3 added:2026-09-27 src:manual}\n'
  );
});

test('addTodo to the empty file first materializes the skeleton', () => {
  const doc = docFrom('');
  const gen = makeSequenceIdGenerator(['t_first']);
  addTodo(doc, { title: 'My first task', added: '2026-09-27' }, gen);
  const out = textOf(doc);
  assert.match(out, /^# Todo\n\n## P0 — Now\n\n## P1 — This week\n\n## P2 — Soon\n- \[ \] My first task \{id:t_first added:2026-09-27 src:manual\}\n\n## P3 — Someday\n\n## Done\n$/);
});

test('completeTodo moves the item to the top of Done, ahead of existing Done items', () => {
  const doc = docFrom(
    '# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n\n## Done\n- [x] Old done {id:t_old done:2026-09-01}\n'
  );
  completeTodo(doc, 't_a', '2026-09-27');
  const out = textOf(doc);
  assert.equal(
    out,
    '# Todo\n\n## P1 — This week\n\n## Done\n- [x] Task A {id:t_a done:2026-09-27}\n- [x] Old done {id:t_old done:2026-09-01}\n'
  );
});

test('completeTodo preserves an item body line', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n  A note about it.\n\n## Done\n');
  completeTodo(doc, 't_a', '2026-09-27');
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n\n## Done\n- [x] Task A {id:t_a done:2026-09-27}\n  A note about it.\n');
});

test('reopenTodo unchecks, drops done, and moves to the default P2', () => {
  const doc = docFrom('# Todo\n\n## P2 — Soon\n\n## Done\n- [x] Task A {id:t_a done:2026-09-01}\n');
  reopenTodo(doc, 't_a');
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P2 — Soon\n- [ ] Task A {id:t_a}\n\n## Done\n');
});

test('updateTodo without a priority change edits the line in place and leaves everything else untouched', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n- [ ] Task B {id:t_b}\n');
  updateTodo(doc, 't_a', { due: '2026-10-01' });
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a due:2026-10-01}\n- [ ] Task B {id:t_b}\n');
});

test('updateTodo with a priority change moves the item to the end of the new section', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n\n## P0 — Now\n- [ ] Urgent {id:t_u}\n');
  updateTodo(doc, 't_a', { priority: 'P0' });
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n\n## P0 — Now\n- [ ] Urgent {id:t_u}\n- [ ] Task A {id:t_a}\n');
});

test('updateTodo setting a field to null removes it', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a due:2026-10-01}\n');
  updateTodo(doc, 't_a', { due: null });
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n');
});

test('removeTodo deletes the item and its body', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n  a note\n- [ ] Task B {id:t_b}\n');
  removeTodo(doc, 't_a');
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n- [ ] Task B {id:t_b}\n');
});

test('assignMissingIds only touches lines that lacked an id', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Hand-typed\n- [ ] Already has one {id:t_a}\n');
  assignMissingIds(doc, makeSequenceIdGenerator(['t_new']));
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n- [ ] Hand-typed {id:t_new}\n- [ ] Already has one {id:t_a}\n');
});

test('findSimilarOpenItem matches a near-duplicate title and ignores done items', () => {
  const doc = docFrom(
    '# Todo\n\n## P1 — This week\n- [ ] Reply to Enzo on Prismo pricing {id:t_a}\n\n## Done\n- [x] Reply to enzo on prismo pricing {id:t_b done:2026-09-01}\n'
  );
  const match = findSimilarOpenItem(doc, 'reply to Enzo on Prismo pricing');
  assert.equal(match?.fields.id, 't_a');
});

test('findSimilarOpenItem returns null when nothing is close enough', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Reply to Enzo on Prismo pricing {id:t_a}\n');
  const match = findSimilarOpenItem(doc, 'Buy groceries for the week');
  assert.equal(match, null);
});

test('addTodo strips newlines from title and free-text fields so the rendered line can never split', () => {
  const doc = docFrom('# Todo\n\n## P2 — Soon\n');
  const gen = makeSequenceIdGenerator(['t_nl']);
  addTodo(doc, { title: 'Call Enzo\nabout pricing', note: 'line one\r\nline two', added: '2026-09-27' }, gen);
  const out = textOf(doc);
  assert.equal(out.split('\n').length, 5); // exactly one line for the item — no stray line breaks
  assert.equal(
    out,
    '# Todo\n\n## P2 — Soon\n- [ ] Call Enzo about pricing {id:t_nl added:2026-09-27 src:manual note:"line one line two"}\n'
  );
});

test('updateTodo strips newlines from a title/note it is given', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Task A {id:t_a}\n');
  updateTodo(doc, 't_a', { title: 'Renamed\ntask', note: 'multi\nline' });
  const out = textOf(doc);
  assert.equal(out, '# Todo\n\n## P1 — This week\n- [ ] Renamed task {id:t_a note:"multi line"}\n');
});

test('assignMissingIds never assigns an id that collides with one already in the file', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Already has this id {id:t_dupe}\n- [ ] Hand-typed\n');
  // The generator offers the colliding id first; assignMissingIds must skip it and take the next one.
  assignMissingIds(doc, makeSequenceIdGenerator(['t_dupe', 't_fresh']));
  const out = textOf(doc);
  assert.equal(
    out,
    '# Todo\n\n## P1 — This week\n- [ ] Already has this id {id:t_dupe}\n- [ ] Hand-typed {id:t_fresh}\n'
  );
});

test('addTodo never assigns a new id that collides with an existing item', () => {
  const doc = docFrom('# Todo\n\n## P1 — This week\n- [ ] Existing {id:t_dupe}\n');
  const gen = makeSequenceIdGenerator(['t_dupe', 't_fresh']);
  const created = addTodo(doc, { title: 'New task', added: '2026-09-27' }, gen);
  assert.equal(created.fields.id, 't_fresh');
});
