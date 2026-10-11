import type { ListRunsOptions, LogsResponse, Run, RunDetail } from './types'

/**
 * Everything the views and hooks know about where data comes from (KTD2). Two
 * implementations: fakeApi (bundled fixtures) and httpApi (the read API). Every method
 * rejects with an ApiError when the server answers with an error, and with the signal's
 * abort reason when the signal fires.
 */
export interface Api {
  /** Runs, newest first. */
  listRuns(options?: ListRunsOptions, signal?: AbortSignal): Promise<Run[]>
  /** One run with its jobs and steps. Rejects with status 404 for an unknown id. */
  getRun(runId: number, signal?: AbortSignal): Promise<RunDetail>
  /** Log lines with `seq > after`, at most `limit`, ordered by `seq`. 404 for an unknown job. */
  getLogs(jobId: number, after: number, limit: number, signal?: AbortSignal): Promise<LogsResponse>
}

/** A failed request. `status` is the HTTP status, or undefined when no response arrived. */
export class ApiError extends Error {
  readonly status: number | undefined

  constructor(message: string, status?: number) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

export function isNotFound(error: unknown): boolean {
  return error instanceof ApiError && error.status === 404
}

export function isAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

/** Rejects the way fetch does when the signal has already fired. */
export function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) {
    throw signal.reason instanceof Error ? signal.reason : new DOMException('Aborted', 'AbortError')
  }
}
