/**
 * E3.4: reads `data/settings.json` for the `get_settings` tool, so the global
 * instruction (PRD C3/C9) can check `proactive` before proposing a task.
 */
import { readFile } from 'node:fs/promises';

export interface Settings {
  [key: string]: unknown; // required for MCP's structuredContent (an index-signature type)
  proactive: boolean;
}

const DEFAULT_SETTINGS: Settings = { proactive: true };

/**
 * Missing file or unparseable JSON both fall back to the default (proactive
 * suggestions on) rather than throwing — a broken settings file shouldn't
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
    return { proactive: typeof parsed.proactive === 'boolean' ? parsed.proactive : DEFAULT_SETTINGS.proactive };
  } catch {
    return DEFAULT_SETTINGS;
  }
}
