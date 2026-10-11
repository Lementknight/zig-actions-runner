import { useEffect, useReducer } from 'react'
import { isAbort, isNotFound, useApi, type Api, type LogLine } from '../api'

// The live tail (R9, R17, KTD4). One sequential loop per mounted job: fetch, append, sleep,
// repeat. One request is in flight by construction, so lines cannot arrive out of order.
// No setInterval anywhere; the next request is scheduled only after the last one settled.

/** The client always asks for this many lines; the API's default is unknown (plan assumptions). */
export const LOG_PAGE_LIMIT = 1000
/** The pause after a short page while the job runs. */
export const POLL_INTERVAL_MS = 1000
/** Waits after the first, second and third consecutive failure; every later one waits the cap. */
export const BACKOFF_MS = [1000, 2000, 4000] as const
export const BACKOFF_CAP_MS = 10_000
/** This many failures in a row and the view shows its retry notice (R17). */
export const RETRY_NOTICE_FAILURES = 3

export type JobLogsStatus = 'loading' | 'live' | 'done' | 'notFound'

export interface JobLogs {
  /** Every line shown so far, ordered by seq with no gaps or duplicates. */
  lines: LogLine[]
  /** `loading` until the first page lands, `live` while polling, `done` or `notFound` when the loop ends. */
  status: JobLogsStatus
  /** The most recent failure, cleared by the next successful request. */
  error: Error | null
  /** Consecutive failed requests; a success resets it to zero. */
  failures: number
  /** True once `failures` reaches RETRY_NOTICE_FAILURES. */
  retrying: boolean
}

interface State {
  jobId: number
  lines: LogLine[]
  status: JobLogsStatus
  error: Error | null
  failures: number
}

type Action =
  | { type: 'append'; jobId: number; lines: LogLine[] }
  | { type: 'done'; jobId: number }
  | { type: 'notFound'; jobId: number }
  | { type: 'failure'; jobId: number; error: Error }

function initialState(jobId: number): State {
  return { jobId, lines: [], status: 'loading', error: null, failures: 0 }
}

function reduce(state: State, action: Action): State {
  // An action for another job starts from a clean slate; the loop for the old job was
  // cancelled before this one started, so this only matters on the first dispatch after a switch.
  const base = state.jobId === action.jobId ? state : initialState(action.jobId)
  switch (action.type) {
    case 'append': {
      // Lines are kept in seq order, so the last one is the high water mark. Anything at or
      // below it was shown already (an overlapping page, or a repeated one after a retry).
      const lastSeq = base.lines.at(-1)?.seq ?? 0
      const fresh = action.lines.filter((line) => line.seq > lastSeq)
      if (fresh.length === 0 && base.status === 'live' && base.failures === 0) return base
      return {
        ...base,
        lines: fresh.length ? base.lines.concat(fresh) : base.lines,
        status: 'live',
        error: null,
        failures: 0,
      }
    }
    case 'done':
      return { ...base, status: 'done', error: null, failures: 0 }
    case 'notFound':
      return { ...base, status: 'notFound', error: null, failures: 0 }
    case 'failure':
      return { ...base, error: action.error, failures: base.failures + 1 }
  }
}

/**
 * Everything one run of the effect owns. The loop reads and writes it directly, so it is
 * the ref the cursor lives in; the cleanup flips `cancelled`, aborts the request in flight
 * and wakes any sleep, and the loop sees all three before its next dispatch.
 */
interface Loop {
  cancelled: boolean
  /** The largest `after` the loop may ask with: max of every `next_after` and every seq seen. */
  cursor: number
  controller: AbortController | undefined
  wake: (() => void) | undefined
}

function sleep(ms: number, loop: Loop): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      loop.wake = undefined
      resolve()
    }, ms)
    loop.wake = () => {
      clearTimeout(timer)
      loop.wake = undefined
      resolve()
    }
  })
}

function backoff(failures: number): number {
  return BACKOFF_MS[failures - 1] ?? BACKOFF_CAP_MS
}

function asError(thrown: unknown): Error {
  return thrown instanceof Error ? thrown : new Error(String(thrown))
}

async function tail(api: Api, jobId: number, loop: Loop, dispatch: (action: Action) => void): Promise<void> {
  let failures = 0
  while (!loop.cancelled) {
    const controller = new AbortController()
    loop.controller = controller
    let response
    try {
      response = await api.getLogs(jobId, loop.cursor, LOG_PAGE_LIMIT, controller.signal)
    } catch (thrown) {
      if (loop.cancelled || isAbort(thrown)) return
      if (isNotFound(thrown)) {
        dispatch({ type: 'notFound', jobId })
        return
      }
      failures += 1
      dispatch({ type: 'failure', jobId, error: asError(thrown) })
      await sleep(backoff(failures), loop)
      continue
    } finally {
      loop.controller = undefined
    }
    if (loop.cancelled) return

    failures = 0
    const lastSeq = response.lines.at(-1)?.seq ?? 0
    loop.cursor = Math.max(loop.cursor, response.next_after, lastSeq)
    dispatch({ type: 'append', jobId, lines: response.lines })

    if (response.job_done && response.lines.length === 0) {
      dispatch({ type: 'done', jobId })
      return
    }
    // A full page may have more behind it, and a page that arrived with job_done set still
    // needs one empty reply to confirm the end. Neither waits.
    if (response.lines.length >= LOG_PAGE_LIMIT || response.job_done) continue
    await sleep(POLL_INTERVAL_MS, loop)
  }
}

/**
 * The lines of one job, live or complete (U3). Mount it with a job id and read `lines`;
 * the loop behind it polls while the job runs, backs off on failures, and stops on its own
 * once the API reports the job done and a request comes back empty. Switching `jobId`
 * cancels the old loop and starts a fresh one at `after=0`.
 */
export function useJobLogs(jobId: number): JobLogs {
  const api = useApi()
  const [state, dispatch] = useReducer(reduce, jobId, initialState)

  useEffect(() => {
    const loop: Loop = { cancelled: false, cursor: 0, controller: undefined, wake: undefined }
    void tail(api, jobId, loop, dispatch)
    return () => {
      loop.cancelled = true
      loop.controller?.abort()
      loop.wake?.()
    }
  }, [api, jobId])

  // Between the render that changed jobId and the effect that starts its loop, the state
  // still belongs to the old job. Show the new job's empty state instead of A's lines under B.
  const current = state.jobId === jobId ? state : initialState(jobId)
  return {
    lines: current.lines,
    status: current.status,
    error: current.error,
    failures: current.failures,
    retrying: current.failures >= RETRY_NOTICE_FAILURES,
  }
}
