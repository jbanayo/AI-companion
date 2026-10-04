import { ItemView } from './model.js';
import { TaskGroup } from './settings.js';

/**
 * The group a task shows under (spec §2.8): its `group` key if that names a defined
 * group, else the first group listing its `project`, else none. Case-insensitive.
 * A display rule only; the file isn't rewritten. Mirrored by effectiveGroup in
 * app/TheListCore/Sources/TheListCore/Settings.swift.
 */
export function effectiveGroup(item: ItemView, groups: TaskGroup[]): TaskGroup | undefined {
  const explicit = item.meta.group?.toLowerCase();
  if (explicit) {
    const match = groups.find((g) => g.id.toLowerCase() === explicit);
    if (match) return match;
  }
  const project = item.meta.project?.toLowerCase();
  if (!project) return undefined;
  return groups.find((g) => g.projects.some((p) => p.toLowerCase() === project));
}
