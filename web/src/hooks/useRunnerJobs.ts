import { useEffect, useState } from 'react'
import { isAbort, useApi, type JobWithSteps, type Run } from '../api'
import { RUNS_LIMIT, sleep } from './useRuns'

/** How often the jobs refresh while the runner page shows them. */
export const RUNNER_JOBS_POLL_MS = 3000

/** A job and the run it belongs to. */
export interface RunnerJob {
  job: JobWithSteps
  run: Run
}

export interface RunnerJobsState {
  /** Jobs that have a runner, from the last successful pass. Null until one finishes. */
  jobs: RunnerJob[] | null
  /** The last pass's failure, or null once a pass succeeds again. */
  error: unknown
  /** When `jobs` arrived, in epoch milliseconds, so durations recompute each poll. */
  fetchedAt: number
}

/**
 * Every job on a runner, running and finished, while `enabled`. The read API has no jobs
 * endpoint, so each pass lists the latest runs and fetches each one (the same walk the
 * contract test does). Disabled, it makes no requests.
 */
export function useRunnerJobs(enabled: boolean): RunnerJobsState {
  const api = useApi()
  const [state, setState] = useState<RunnerJobsState>({ jobs: null, error: null, fetchedAt: Date.now() })

  useEffect(() => {
    if (!enabled) return
    const controller = new AbortController()
    const { signal } = controller

    async function loop() {
      while (!signal.aborted) {
        try {
          const runs = await api.listRuns({ limit: RUNS_LIMIT }, signal)
          const details = await Promise.all(runs.map((run) => api.getRun(run.id, signal)))
          if (signal.aborted) return
          const jobs = details.flatMap(({ jobs: runJobs, ...run }) =>
            runJobs.filter((job) => job.runner_name !== null).map((job) => ({ job, run })),
          )
          setState({ jobs, error: null, fetchedAt: Date.now() })
        } catch (error) {
          if (signal.aborted || isAbort(error)) return
          setState((prev) => ({ ...prev, error }))
        }
        await sleep(RUNNER_JOBS_POLL_MS, signal)
      }
    }

    void loop()
    return () => controller.abort()
  }, [api, enabled])

  return state
}
