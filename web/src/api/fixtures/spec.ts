import type { LogStream } from '../types'

// The fixture format the fake API reads. A fixture is a timeline, not a snapshot: every
// time is an offset in milliseconds, and the fake derives each status from the clock
// (KTD3). A run whose whole timeline lies in the past reads as a finished run.

export interface FakeLine {
  /** When the line is released, in ms after its step starts. Keep it below the step's durationMs. */
  atMs: number
  text: string
  stream?: LogStream
}

export interface FakeStep {
  name: string
  durationMs: number
  /** The step's conclusion once it completes. Defaults to success. */
  conclusion?: string
  lines?: FakeLine[]
  /**
   * Hide the step's row until this long after the step starts, so its first lines arrive
   * before the row does (R18). Without it the row exists from the moment the job starts.
   */
  rowDelayMs?: number
}

export interface FakeJob {
  id: number
  name: string
  runnerName?: string | null
  /** When the job starts, in ms after its run is created. Queued until then. */
  startMs: number
  /** Defaults to failure if any step failed, cancelled if any was cancelled, else success. */
  conclusion?: string
  steps: FakeStep[]
}

export interface FakeRun {
  id: number
  repo: string
  workflow: string
  event: string | null
  branch: string | null
  sha: string | null
  /** When the run is created, in ms relative to the fake's clock origin. Negative is the past. */
  createdMs: number
  /** A run with no jobs stays queued. */
  jobs: FakeJob[]
}

/** Lines released one every `intervalMs`, starting at `startMs`. */
export function every(
  intervalMs: number,
  texts: string[],
  options: { startMs?: number; stream?: LogStream } = {},
): FakeLine[] {
  const startMs = options.startMs ?? 0
  return texts.map((text, i) => ({ atMs: startMs + i * intervalMs, text, stream: options.stream }))
}

export const MINUTE = 60_000
export const HOUR = 60 * MINUTE

/** ANSI escape helpers for fixture text. */
export const ansi = {
  red: (s: string) => `\u001b[31m${s}\u001b[0m`,
  green: (s: string) => `\u001b[32m${s}\u001b[0m`,
  yellow: (s: string) => `\u001b[33m${s}\u001b[0m`,
  blue: (s: string) => `\u001b[34m${s}\u001b[0m`,
  cyan: (s: string) => `\u001b[36m${s}\u001b[0m`,
  gray: (s: string) => `\u001b[90m${s}\u001b[0m`,
  bold: (s: string) => `\u001b[1m${s}\u001b[0m`,
}

/** The lines GitHub's runner prints at the start of every job. */
export function setUpJobLines(runnerName: string): FakeLine[] {
  return every(150, [
    `Current runner version: '0.1.0-zig'`,
    `Runner name: '${runnerName}'`,
    'Operating System',
    '  Ubuntu 24.04 LTS',
    `Prepare workflow directory`,
    `Prepare all required actions`,
  ])
}
