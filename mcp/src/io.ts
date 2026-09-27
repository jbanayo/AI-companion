import { mkdir, open, readFile, rename, stat, unlink } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { Document } from './model.js';
import { parseDocument } from './parse.js';
import { serialize } from './serialize.js';
import { assignMissingIds } from './ops.js';

const LOCK_STALE_MS = 5000;
const LOCK_TIMEOUT_MS = 3000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Exclusive advisory lock via `open(path, 'wx')` (fails if the file exists).
 * A lock older than LOCK_STALE_MS is assumed to be left by a crashed
 * process and is cleared. This is what makes concurrent writers from
 * separate processes (Claude, the app, a hand edit mid-flight) safe —
 * spec §3.5 / PRD D4, story E1.3.
 */
async function acquireLock(lockPath: string): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      const fh = await open(lockPath, 'wx');
      await fh.close();
      return;
    } catch (err: any) {
      if (err.code !== 'EEXIST') throw err;
      try {
        const st = await stat(lockPath);
        if (Date.now() - st.mtimeMs > LOCK_STALE_MS) {
          await unlink(lockPath).catch(() => {});
          continue;
        }
      } catch {
        continue; // lock vanished between the failed open and this stat; retry
      }
      if (Date.now() - start > LOCK_TIMEOUT_MS) {
        throw new Error(`Timed out waiting for lock: ${lockPath}`);
      }
      await sleep(10 + Math.random() * 25);
    }
  }
}

async function releaseLock(lockPath: string): Promise<void> {
  await unlink(lockPath).catch(() => {});
}

/**
 * Atomic write: write to a temp file in the same directory, then rename
 * over the target. rename() is atomic on the same filesystem, so a reader
 * (or a crash) never observes a half-written file (spec §3.5, story E1.2).
 */
export async function writeFileAtomic(path: string, bytes: Uint8Array): Promise<void> {
  const dir = dirname(path);
  await mkdir(dir, { recursive: true });
  const tmp = join(dir, `.${basename(path)}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  const fh = await open(tmp, 'w');
  try {
    await fh.writeFile(bytes);
    await fh.sync();
  } finally {
    await fh.close();
  }
  await rename(tmp, path);
}

/** Returns the file's raw bytes, or null if it doesn't exist yet (treated as an empty file). */
async function readRaw(path: string): Promise<Uint8Array | null> {
  try {
    return await readFile(path);
  } catch (err: any) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * Reads the file, hands it to `mutate`, and writes the result back —
 * guarded by a lock so two callers (Claude Code and Claude Desktop, or a
 * hand edit mid-flight) can't lose each other's change (spec §3.5, E1.3).
 * `mutate` always sees a *fresh* read taken after the lock was acquired.
 *
 * Skips the write entirely when the serialized bytes come out identical to
 * what was on disk (e.g. a `list_todos` that didn't need to assign any
 * ids) — a query shouldn't touch the file's mtime or trigger the app's
 * FSEvents watcher for a change that never happened.
 *
 * Empty-file skeleton substitution (spec §3.4) happens inside the
 * individual ops (e.g. addTodo), not here, so it also applies to callers
 * that use ops.ts directly without going through this function.
 */
export async function withTodoFile<T>(path: string, mutate: (doc: Document) => T): Promise<T> {
  const lockPath = `${path}.lock`;
  await mkdir(dirname(path), { recursive: true });
  await acquireLock(lockPath);
  try {
    const raw = await readRaw(path);
    const doc = parseDocument(raw ?? new TextEncoder().encode(''));
    assignMissingIds(doc); // spec §3.2: every operation runs this first
    const result = mutate(doc);
    const bytes = serialize(doc);
    if (raw === null || !bytesEqual(raw, bytes)) {
      await writeFileAtomic(path, bytes);
    }
    return result;
  } finally {
    await releaseLock(lockPath);
  }
}

/** Read-only view; no lock needed since nothing is written. */
export async function readTodoFile(path: string): Promise<Document> {
  const raw = await readRaw(path);
  return parseDocument(raw ?? new TextEncoder().encode(''));
}
