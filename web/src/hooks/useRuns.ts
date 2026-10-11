import { useEffect, useState } from 'react'
import { isAbort, useApi, type Run } from '../api'

/** How often the run list refreshes while it is open (R14). */
export const RUNS_POLL_MS = 3000

/** The first page of runs; older pages are out of scope for the demo. */
export const RUNS_LIMIT = 50

export interface RunsState {
  /** Runs, newest first, from the last successful request. Null until the first one answers. */
  runs: Run[] | null
  /** The last request's failure, or null once a request succeeds again. */
  error: unknown
  /** When `runs` arrived, in epoch milliseconds, so ages and durations recompute each poll. */
  fetchedAt: number
}

/**
 * The run list, refreshed about every 3 seconds while mounted (R14). One request is in flight
 * at a time: fetch, store, sleep, repeat. A failed request keeps the runs already loaded and
 * reports the error (R17); the next poll retries on the same schedule. Unmounting aborts the
 * request in flight and ends the loop.
 */
export function useRuns(): RunsState {
  const api = useApi()
  const [state, setState] = useState<RunsState>({ runs: null, error: null, fetchedAt: Date.now() })

  useEffect(() => {
    const controller = new AbortController()
    const { signal } = controller

    async function loop() {
      while (!signal.aborted) {
        try {
          const runs = await api.listRuns({ limit: RUNS_LIMIT }, signal)
          if (signal.aborted) return
          setState({ runs, error: null, fetchedAt: Date.now() })
        } catch (error) {
          if (signal.aborted || isAbort(error)) return
          setState((prev) => ({ ...prev, error }))
        }
        await sleep(RUNS_POLL_MS, signal)
      }
    }

    void loop()
    return () => controller.abort()
  }, [api])

  return state
}

/** Resolves after `ms`, or as soon as the signal aborts. */
export function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(done, ms)
    signal.addEventListener('abort', done, { once: true })
    function done() {
      clearTimeout(timer)
      signal.removeEventListener('abort', done)
      resolve()
    }
  })
}
