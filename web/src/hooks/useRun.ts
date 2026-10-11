import { useEffect, useState } from 'react'
import { isAbort, isNotFound, useApi, type RunDetail } from '../api'

/** How often a run is refetched while it is not completed (R15). */
export const RUN_POLL_MS = 2000

export interface RunState {
  /** The run with its jobs and steps, from the last successful request. Null until one answers. */
  run: RunDetail | null
  /** True while the API answers 404 for this id. Polling continues, so it clears once the run is recorded. */
  notFound: boolean
  /** The last request's failure, or null once a request succeeds again. */
  error: Error | null
  /** Consecutive failed requests; a success resets it to zero. */
  failures: number
  /** When `run` arrived, in epoch milliseconds. */
  fetchedAt: number
}

interface State extends RunState {
  runId: number
}

function initialState(runId: number): State {
  return { runId, run: null, notFound: false, error: null, failures: 0, fetchedAt: Date.now() }
}

/**
 * One run, refetched about every 2 seconds until its status is `completed`, then left alone
 * (R15). The run page and the job view share it, so job and step status and durations move
 * in place on both. A failed request keeps the run already loaded and counts the failure
 * (R17); a 404 reports `notFound` and keeps polling until the run exists. Switching `runId` starts over.
 */
export function useRun(runId: number): RunState {
  const api = useApi()
  const [state, setState] = useState<State>(() => initialState(runId))

  useEffect(() => {
    const controller = new AbortController()
    const { signal } = controller
    const update = (change: (prev: State) => State) =>
      setState((prev) => change(prev.runId === runId ? prev : initialState(runId)))

    async function loop() {
      while (!signal.aborted) {
        try {
          const run = await api.getRun(runId, signal)
          if (signal.aborted) return
          update((prev) => ({ ...prev, run, notFound: false, error: null, failures: 0, fetchedAt: Date.now() }))
          if (run.status === 'completed') return
        } catch (thrown) {
          if (signal.aborted || isAbort(thrown)) return
          if (isNotFound(thrown)) {
            // Not final: the runner records a run the moment it takes the job, so a link
            // opened a beat early (or this page reloaded) finds it on a later poll.
            update((prev) => ({ ...prev, notFound: true, error: null, failures: 0 }))
          } else {
            const error = thrown instanceof Error ? thrown : new Error(String(thrown))
            update((prev) => ({ ...prev, error, failures: prev.failures + 1 }))
          }
        }
        await sleep(RUN_POLL_MS, signal)
      }
    }

    void loop()
    return () => controller.abort()
  }, [api, runId])

  // Between the render that changed runId and the effect that fetches it, the state still
  // belongs to the old run. Show the new run's empty state instead.
  const current = state.runId === runId ? state : initialState(runId)
  return {
    run: current.run,
    notFound: current.notFound,
    error: current.error,
    failures: current.failures,
    fetchedAt: current.fetchedAt,
  }
}

/** Resolves after `ms`, or as soon as the signal aborts. */
function sleep(ms: number, signal: AbortSignal): Promise<void> {
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
