/**
 * E3.4: reads `data/settings.json` for the `get_settings` tool, so the global
 * instruction (PRD C3/C9) can check `proactive` before proposing a task.
 * E8.1: also reads the task groups (spec §2.8).
 */
import { readFile } from 'node:fs/promises';

export interface TaskGroup {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  id: string;
  name: string;
  /** Project tags that belong to this group when a task has no `group` key. */
  projects: string[];
}

export interface Settings {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  proactive: boolean;
  groups: TaskGroup[];
}

const DEFAULT_SETTINGS: Settings = { proactive: true, groups: [] };

/** Keeps well-formed groups and drops the rest, so one bad entry doesn't hide every group. */
export function parseGroups(value: unknown): TaskGroup[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const groups: TaskGroup[] = [];
  for (const g of value) {
    if (!g || typeof g !== 'object') continue;
    const { id, name, projects } = g as Record<string, unknown>;
    if (typeof id !== 'string' || !id.trim() || seen.has(id.toLowerCase())) continue;
    seen.add(id.toLowerCase());
    groups.push({
      id,
      name: typeof name === 'string' && name.trim() ? name : id,
      projects: Array.isArray(projects) ? projects.filter((p): p is string => typeof p === 'string') : [],
    });
  }
  return groups;
}

/**
 * Missing file or unparseable JSON both fall back to the default (proactive
 * suggestions on, no groups) rather than throwing — a broken settings file shouldn't
 * take down every tool call, and "on" is the documented default (PRD §11.2).
 */
export async function readSettings(settingsPath: string): Promise<Settings> {
  let text: string;
  try {
    text = await readFile(settingsPath, 'utf-8');
  } catch (err: any) {
    if (err.code === 'ENOENT') return DEFAULT_SETTINGS;
    throw err;
  }

  try {
    const parsed = JSON.parse(text);
    return {
      proactive: typeof parsed.proactive === 'boolean' ? parsed.proactive : DEFAULT_SETTINGS.proactive,
      groups: parseGroups(parsed.groups),
    };
  } catch {
    return DEFAULT_SETTINGS;
  }
}
