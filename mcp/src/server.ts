import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
// zod/v4, not the classic 'zod' (v3) export: with this SDK version, registering a tool
// through the v3 API hits a real TS compiler bug (TS2589, "type instantiation is
// excessively deep") on every registerTool() call, even with a single flat field —
// confirmed by isolating a minimal repro. zod/v4 is also what the SDK's own examples use.
import * as z from 'zod/v4';
import { addTodoTool, completeTodoTool, listTodosTool, updateTodoTool } from './tools.js';
import { readSettings } from './settings.js';

const PRIORITY = z.enum(['P0', 'P1', 'P2', 'P3']);
const DATE = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'must be YYYY-MM-DD');

const ITEM_SHAPE = {
  id: z.string(),
  title: z.string(),
  priority: z.enum(['P0', 'P1', 'P2', 'P3', 'Done']),
  done: z.boolean(),
  due: z.string().optional(),
  project: z.string().optional(),
  link: z.string().optional(),
  note: z.string().optional(),
};

export interface ServerConfig {
  dataPath: string;
  /** How items added here are tagged (spec `src`): 'claude-code' or 'claude-desktop'. */
  src: string;
  /** Path to `data/settings.json` (PRD C9). */
  settingsPath: string;
}

export function createServer(config: ServerConfig): McpServer {
  const server = new McpServer({ name: 'the-list', version: '0.1.0' });

  server.registerTool(
    'add_todo',
    {
      title: 'Add a todo',
      description:
        "Adds a task to Julius's todo list (The List). Use this when he explicitly asks you to " +
        "('put this in my todo list'), or — after he confirms — when you notice something in the " +
        'conversation that is his responsibility to act on. Before adding, check if a very similar ' +
        "open item already exists; if `duplicate` comes back true, ask whether to update the existing " +
        'one instead of adding a new one — or, if he confirms it really is a separate task, call this ' +
        'again with `allowDuplicate: true`.',
      inputSchema: {
        title: z.string().min(1).describe('The task, written the way Julius would say it.'),
        priority: PRIORITY.optional().describe('P0 Now, P1 This week, P2 Soon (default), P3 Someday.'),
        due: DATE.optional().describe('Due date, if one was mentioned.'),
        project: z.string().optional().describe('Project tag, e.g. solomon, lumen, prismo, personal.'),
        link: z.string().optional().describe('The file, URL, or ClickUp task this item relates to.'),
        note: z.string().optional().describe('Any extra context worth keeping.'),
        allowDuplicate: z
          .boolean()
          .optional()
          .describe('Set true to add anyway after Julius confirms a fuzzy-matched title is a separate task.'),
      },
      outputSchema: {
        added: z.boolean(),
        duplicate: z.boolean().describe('True if this matched an existing open item instead of being added.'),
        item: z.object(ITEM_SHAPE),
      },
    },
    async (args) => {
      const result = await addTodoTool(config.dataPath, args, config.src);
      const text = result.duplicate
        ? `Already on the list as "${result.item.title}" (${result.item.priority}${result.item.due ? `, due ${result.item.due}` : ''}, id ${result.item.id}). Update it instead of adding a new one?`
        : `Added "${result.item.title}" to ${result.item.priority}${result.item.due ? ` (due ${result.item.due})` : ''}. id ${result.item.id}.`;
      return { content: [{ type: 'text' as const, text }], structuredContent: result };
    }
  );

  server.registerTool(
    'list_todos',
    {
      title: 'List todos',
      description:
        "Lists items from Julius's todo list (The List), sorted by priority (most urgent first). " +
        'An open item due today or earlier is shown as P0 even if it was filed under a lower priority.',
      inputSchema: {
        status: z.enum(['open', 'done', 'all']).optional().describe('Defaults to open.'),
        priority: PRIORITY.optional().describe('Filter to items currently showing at this priority.'),
        project: z.string().optional().describe('Filter to one project tag.'),
      },
      outputSchema: {
        items: z.array(z.object(ITEM_SHAPE)),
        count: z.number(),
      },
    },
    async (args) => {
      const result = await listTodosTool(config.dataPath, args);
      const text =
        result.count === 0
          ? 'Nothing matches.'
          : result.items.map((i) => `${i.priority} — ${i.title}${i.due ? ` (due ${i.due})` : ''} [${i.id}]`).join('\n');
      return { content: [{ type: 'text' as const, text }], structuredContent: result };
    }
  );

  server.registerTool(
    'complete_todo',
    {
      title: 'Complete a todo',
      description: 'Marks a task done by id and moves it to the top of Done.',
      inputSchema: { id: z.string().describe('The item id, e.g. t_8f2a.') },
      outputSchema: { completed: z.boolean(), item: z.object(ITEM_SHAPE).optional() },
    },
    async ({ id }) => {
      const result = await completeTodoTool(config.dataPath, id);
      const text = result.completed ? `Marked "${result.item?.title}" done.` : `No open item with id ${id}.`;
      return { content: [{ type: 'text' as const, text }], structuredContent: result };
    }
  );

  server.registerTool(
    'update_todo',
    {
      title: 'Update a todo',
      description:
        'Changes fields on an existing task by id. Pass null for due/project/link/note to remove that ' +
        'field. Changing priority moves the item to the end of the new section.',
      inputSchema: {
        id: z.string().describe('The item id, e.g. t_8f2a.'),
        title: z.string().optional(),
        priority: PRIORITY.optional(),
        due: DATE.nullable().optional(),
        project: z.string().nullable().optional(),
        link: z.string().nullable().optional(),
        note: z.string().nullable().optional(),
      },
      outputSchema: { updated: z.boolean(), item: z.object(ITEM_SHAPE).optional() },
    },
    async ({ id, ...fields }) => {
      const result = await updateTodoTool(config.dataPath, id, fields);
      const text = result.updated ? `Updated "${result.item?.title}".` : `No item with id ${id}.`;
      return { content: [{ type: 'text' as const, text }], structuredContent: result };
    }
  );

  server.registerTool(
    'get_settings',
    {
      title: 'Get settings',
      description:
        "Reads Julius's The List settings. Check `proactive` before proposing a task he didn't " +
        "explicitly ask for (PRD C9): when it's false, don't suggest — only add what he asks for directly.",
      inputSchema: {},
      outputSchema: { proactive: z.boolean() },
    },
    async () => {
      const settings = await readSettings(config.settingsPath);
      const text = settings.proactive
        ? 'Proactive suggestions are on.'
        : 'Proactive suggestions are off — only add tasks Julius explicitly asks for.';
      return { content: [{ type: 'text' as const, text }], structuredContent: settings };
    }
  );

  return server;
}
