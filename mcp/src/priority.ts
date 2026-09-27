import { ItemView, Section } from './model.js';

const ORDER: Record<Section, number> = { P0: 0, P1: 1, P2: 2, P3: 3, Done: 4 };
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** True for a well-formed YYYY-MM-DD date. Malformed dates are ignored by sorting/overdue checks (spec §2.6). */
function isValidDate(s: string): boolean {
  if (!DATE_RE.test(s)) return false;
  const d = new Date(s + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/**
 * The priority shown in the UI (PRD §6.3): an open item due today or
 * earlier displays as P0, without the file being rewritten. Everything
 * else shows its stored section priority.
 */
export function displayPriority(item: ItemView, today: string): Section {
  if (!item.done) {
    const due = item.meta.due;
    if (due && isValidDate(due) && due <= today) return 'P0';
  }
  return item.priority;
}

export function isOverdue(item: ItemView, today: string): boolean {
  if (item.done) return false;
  const due = item.meta.due;
  return !!due && isValidDate(due) && due < today;
}

/** Sorts by display priority, then by due date (soonest/undated-last), then by title. */
export function sortByDisplayPriority(items: ItemView[], today: string): ItemView[] {
  return [...items].sort((a, b) => {
    const pa = ORDER[displayPriority(a, today)];
    const pb = ORDER[displayPriority(b, today)];
    if (pa !== pb) return pa - pb;
    const da = a.meta.due && isValidDate(a.meta.due) ? a.meta.due : '9999-99-99';
    const db = b.meta.due && isValidDate(b.meta.due) ? b.meta.due : '9999-99-99';
    if (da !== db) return da < db ? -1 : 1;
    return a.title.localeCompare(b.title);
  });
}

/**
 * Today's date in the server's local timezone (Julius's Mac), not UTC.
 * `toISOString()` reports UTC, which lands on the wrong calendar day for
 * several hours a day at UTC+8 — a task added at 11pm would get tomorrow's
 * `added` date, and an item due today wouldn't show as P0 until 8am.
 */
export function today(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
