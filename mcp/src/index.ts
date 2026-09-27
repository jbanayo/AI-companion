#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { join } from 'node:path';
import { createServer } from './server.js';

// dist/index.js -> ../.. is AI Companion/, whose data/ folder holds the real TODO.md (gitignored).
const defaultDataDir = join(import.meta.dirname, '..', '..', 'data');
const dataDir = process.env.THE_LIST_DATA_DIR ?? defaultDataDir;
const dataPath = join(dataDir, 'TODO.md');

// Set per client in its MCP registration (claude mcp add --env / claude_desktop_config.json "env"),
// so items added from each client are tagged with where they came from (spec `src`).
const src = process.env.THE_LIST_SRC ?? 'claude-code';

const server = createServer({ dataPath, src });
const transport = new StdioServerTransport();

server.connect(transport).catch((err) => {
  console.error('the-list-mcp failed to start:', err);
  process.exit(1);
});
