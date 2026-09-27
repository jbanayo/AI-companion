import { ItemFields, KNOWN_KEYS } from './model.js';

/** Quote a value if it needs it, per spec §3.3. */
function renderValue(value: string): string {
  if (value === '' || /[\s{}"]/.test(value)) {
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }
  return value;
}

/** Renders one item line in canonical form (spec §3.3). Never touches body lines. */
export function renderItemLine(fields: ItemFields): string {
  const pairs: string[] = [];
  if (fields.id) pairs.push(`id:${renderValue(fields.id)}`);
  for (const key of KNOWN_KEYS) {
    const v = fields.meta.get(key);
    if (v !== undefined) pairs.push(`${key}:${renderValue(v)}`);
  }
  // Unknown keys, in original encounter order.
  for (const [key, value] of fields.meta) {
    if ((KNOWN_KEYS as readonly string[]).includes(key)) continue;
    pairs.push(`${key}:${renderValue(value)}`);
  }
  const checkbox = fields.done ? '[x]' : '[ ]';
  const suffix = pairs.length > 0 ? ` {${pairs.join(' ')}}` : '';
  return `- ${checkbox} ${fields.title}${suffix}`;
}
