import { useEffect, useState } from 'react'
import { isAbort, useApi, type Runner } from '../api'
import { sleep } from './useRuns'

/** How often the runner list refreshes while it is open. */
export const RUNNERS_POLL_MS = 3000

export interface RunnersState {
  /** Runners from the last successful request. Null until the first one answers. */
  runners: Runner[] | null
  /** The last request's failure, or null once a request succeeds again. */
  error: unknown
  /** When `runners` arrived, in epoch milliseconds, so last-seen ages recompute each poll. */
  fetchedAt: number
}

/** The runner list, refreshed about every 3 seconds while mounted; failure handling as in useRuns. */
export function useRunners(): RunnersState {
  const api = useApi()
  const [state, setState] = useState<RunnersState>({ runners: null, error: null, fetchedAt: Date.now() })

  useEffect(() => {
    const controller = new AbortController()
    const { signal } = controller

    async function loop() {
      while (!signal.aborted) {
        try {
          const runners = await api.listRunners(signal)
          if (signal.aborted) return
          setState({ runners, error: null, fetchedAt: Date.now() })
        } catch (error) {
          if (signal.aborted || isAbort(error)) return
          setState((prev) => ({ ...prev, error }))
        }
        await sleep(RUNNERS_POLL_MS, signal)
      }
    }

    void loop()
    return () => controller.abort()
  }, [api])

  return state
}
