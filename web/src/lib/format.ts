// Display formatting for durations, ages and commits. Pure: every function that depends
// on the current time takes it as an argument.

/** "0s", "59s", "1m 1s", "1h 1m 1s", as GitHub prints durations. Negative input is 0s. */
export function formatDuration(seconds: number): string {
  const total = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  if (h > 0) return `${h}h ${m}m ${s}s`
  if (m > 0) return `${m}m ${s}s`
  return `${s}s`
}

/** Whole seconds from `start` to `end`, or to `now` while `end` is null. Null if never started. */
export function elapsedSeconds(start: string | null, end: string | null, now: number): number | null {
  if (start === null) return null
  const from = Date.parse(start)
  const to = end === null ? now : Date.parse(end)
  if (Number.isNaN(from) || Number.isNaN(to)) return null
  return Math.max(0, Math.floor((to - from) / 1000))
}

/**
 * A run's duration in seconds. Runs have no `started_at`, so it runs from `created_at`:
 * to `completed_at` once completed, to `now` while in progress. Null while queued.
 */
export function runDurationSeconds(
  run: { status: string; created_at: string; completed_at: string | null },
  now: number,
): number | null {
  if (run.status === 'queued') return null
  return elapsedSeconds(run.created_at, run.completed_at, now)
}

const relative = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ['year', 365 * 24 * 3600],
  ['month', 30 * 24 * 3600],
  ['week', 7 * 24 * 3600],
  ['day', 24 * 3600],
  ['hour', 3600],
  ['minute', 60],
]

/** "now", "3 minutes ago", "yesterday", "2 weeks ago". Future times read as "now". */
export function formatAge(iso: string, now: number): string {
  const then = Date.parse(iso)
  if (Number.isNaN(then)) return ''
  const seconds = Math.max(0, Math.floor((now - then) / 1000))
  for (const [unit, size] of UNITS) {
    if (seconds >= size) return relative.format(-Math.floor(seconds / size), unit)
  }
  return 'now'
}

/** The first 7 characters of a commit sha, or an empty string when there is none. */
export function shortSha(sha: string | null): string {
  return sha ? sha.slice(0, 7) : ''
}
