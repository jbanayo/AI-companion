/**
 * Tool business logic, kept separate from MCP wiring (server.ts) so it's
 * testable as plain async functions without spinning up the stdio protocol.
 */
import { ItemView } from './model.js';
import { deriveViews } from './parse.js';
import { withTodoFile } from './io.js';
import { addTodo, completeTodo, findSimilarOpenItem, updateTodo, DUPLICATE_THRESHOLD } from './ops.js';
import { displayPriority, sortByDisplayPriority, today } from './priority.js';
import { effectiveGroup } from './groups.js';
import { TaskGroup } from './settings.js';

export interface ItemSummary {
  id: string;
  title: string;
  priority: 'P0' | 'P1' | 'P2' | 'P3' | 'Done';
  done: boolean;
  due?: string;
  project?: string;
  /** The effective group's id (spec §2.8), from the `group` key or the project's group. */
  group?: string;
  link?: string;
  note?: string;
}

function summarize(view: ItemView, t: string, groups: TaskGroup[]): ItemSummary {
  return {
    id: view.id as string, // always present: assignMissingIds runs before every write
    title: view.title,
    priority: displayPriority(view, t),
    done: view.done,
    due: view.meta.due,
    project: view.meta.project,
    group: effectiveGroup(view, groups)?.id,
    link: view.meta.link,
    note: view.meta.note,
  };
}

export interface AddTodoArgs {
  title: string;
  priority?: 'P0' | 'P1' | 'P2' | 'P3';
  due?: string;
  project?: string;
  group?: string;
  link?: string;
  note?: string;
  /** Skip the fuzzy-duplicate check (PRD C7) — for a title that's legitimately close to an existing one. */
  allowDuplicate?: boolean;
}

export interface AddTodoResult {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  added: boolean;
  duplicate: boolean;
  item: ItemSummary;
}

/** E2.1 + E2.4: adds a task, unless an open item is already a close match (spec/PRD C7). */
export async function addTodoTool(
  dataPath: string,
  args: AddTodoArgs,
  src: string,
  groups: TaskGroup[] = []
): Promise<AddTodoResult> {
  const { allowDuplicate, ...addInput } = args;
  return withTodoFile(dataPath, (doc) => {
    const t = today();
    if (!allowDuplicate) {
      const dup = findSimilarOpenItem(doc, args.title);
      if (dup) {
        const view = deriveViews(doc).items.find((i) => i.id === dup.fields.id)!;
        return { added: false, duplicate: true, item: summarize(view, t, groups) };
      }
    }
    const created = addTodo(doc, { ...addInput, src, added: t });
    const view = deriveViews(doc).items.find((i) => i.id === created.fields.id)!;
    return { added: true, duplicate: false, item: summarize(view, t, groups) };
  });
}

export interface ListTodosArgs {
  status?: 'open' | 'done' | 'all';
  priority?: 'P0' | 'P1' | 'P2' | 'P3';
  project?: string;
  /** Filter to one group id, matched on the effective group. */
  group?: string;
}

export interface ListTodosResult {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  items: ItemSummary[];
  count: number;
}

/**
 * E2.3: lists todos, sorted by display priority (overdue/due-today shows as P0 — PRD §6.3).
 *
 * Goes through withTodoFile (not the plain read-only path) even though this is a query: a
 * hand-typed item has no id until something assigns one (spec D3), and every other tool takes
 * an id, so a listed item needs a real id to be actionable. Running assignMissingIds here is an
 * idempotent, self-healing write — a no-op on disk when there was nothing to assign.
 */
export async function listTodosTool(
  dataPath: string,
  args: ListTodosArgs,
  groups: TaskGroup[] = []
): Promise<ListTodosResult> {
  const t = today();
  const status = args.status ?? 'open';

  return withTodoFile(dataPath, (doc) => {
    let items = deriveViews(doc).items.filter((i) => {
      if (status === 'open' && i.done) return false;
      if (status === 'done' && !i.done) return false;
      if (args.priority && displayPriority(i, t) !== args.priority) return false;
      if (args.project && i.meta.project !== args.project) return false;
      if (args.group && effectiveGroup(i, groups)?.id.toLowerCase() !== args.group.toLowerCase()) return false;
      return true;
    });
    items = sortByDisplayPriority(items, t);

    return { items: items.map((i) => summarize(i, t, groups)), count: items.length };
  });
}

export interface CompleteTodoResult {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  completed: boolean;
  item?: ItemSummary;
}

/** E2.3: marks a task done and moves it to the top of Done. */
export async function completeTodoTool(
  dataPath: string,
  id: string,
  groups: TaskGroup[] = []
): Promise<CompleteTodoResult> {
  return withTodoFile(dataPath, (doc) => {
    const t = today();
    const changed = completeTodo(doc, id, t);
    if (!changed) return { completed: false };
    const view = deriveViews(doc).items.find((i) => i.id === id)!;
    return { completed: true, item: summarize(view, t, groups) };
  });
}

export interface UpdateTodoArgs {
  title?: string;
  priority?: 'P0' | 'P1' | 'P2' | 'P3';
  due?: string | null;
  project?: string | null;
  group?: string | null;
  link?: string | null;
  note?: string | null;
}

export interface UpdateTodoResult {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  updated: boolean;
  item?: ItemSummary;
}

/** E2.3: changes fields on an existing task; a priority change moves it to the end of the new section. */
export async function updateTodoTool(
  dataPath: string,
  id: string,
  fields: UpdateTodoArgs,
  groups: TaskGroup[] = []
): Promise<UpdateTodoResult> {
  return withTodoFile(dataPath, (doc) => {
    const changed = updateTodo(doc, id, fields);
    if (!changed) return { updated: false };
    const view = deriveViews(doc).items.find((i) => i.id === id)!;
    return { updated: true, item: summarize(view, today(), groups) };
  });
}

export { DUPLICATE_THRESHOLD };
