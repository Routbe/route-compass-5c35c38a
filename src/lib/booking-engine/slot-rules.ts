/**
 * Public slot rules for teams. Each host's starts are computed on that host's
 * own timeline first and only then combined, so a slot is never offered when
 * the free time comes from different hosts stitched together (host A free
 * 10:00–10:15 + host B free 10:15–10:30 is not a 30-minute slot).
 */
import { bookableStarts, emptyDay, type DayBits } from "./bitmap";
import type { EventTypeRules } from "./types";

export type HostDay = { day: string; bits: DayBits };

/** Consecutive days from the first to the last given day; missing days are busy. */
export function contiguousDays(days: HostDay[]): HostDay[] {
  if (!days.length) return [];
  const sorted = [...days].sort((a, b) => a.day.localeCompare(b.day));
  const map = new Map(sorted.map((d) => [d.day, d.bits]));
  const out: HostDay[] = [];
  const end = new Date(`${sorted[sorted.length - 1]!.day}T00:00:00Z`).getTime();
  for (let t = new Date(`${sorted[0]!.day}T00:00:00Z`).getTime(); t <= end; t += 86400000) {
    const k = new Date(t).toISOString().slice(0, 10);
    out.push({ day: k, bits: map.get(k) ?? emptyDay() });
  }
  return out;
}

/**
 * COLLECTIVE: a start every one of `hostCount` hosts can take (a host without
 * cache = busy). Otherwise: a start at least one host can take on their own.
 */
export function mergeHostStarts(
  byHost: Map<number, HostDay[]>,
  hostCount: number,
  collective: boolean,
  rules: EventTypeRules,
  now: Date,
): Date[] {
  const perHost: Set<number>[] = [];
  for (let ordinal = 1; ordinal <= hostCount; ordinal++) {
    const days = contiguousDays(byHost.get(ordinal) ?? []);
    perHost.push(new Set(bookableStarts(days, rules, now).map((d) => d.getTime())));
  }
  if (!perHost.length) return [];
  let result: Set<number>;
  if (collective) {
    result = new Set([...perHost[0]!].filter((t) => perHost.every((s) => s.has(t))));
  } else {
    result = new Set(perHost.flatMap((s) => [...s]));
  }
  return [...result].sort((a, b) => a - b).map((t) => new Date(t));
}
