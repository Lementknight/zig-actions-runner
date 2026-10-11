import { throwIfAborted, type Api } from '../api/Api'
import type { ListRunsOptions, LogsResponse, Run, RunDetail } from '../api/types'

// A controllable Api for tests (KTD9). Each method is a channel: a request waits until the
// test pushes a response (or an Error to reject with), takes one already queued, or falls
// back to a sticky response set with always(). Every request's arguments are recorded.

type Response<T> = T | Error

interface Waiter<T> {
  resolve: (value: T) => void
  reject: (error: unknown) => void
}

export class Channel<Args, T> {
  /** Arguments of every request, in order, including ones still waiting. */
  readonly calls: Args[] = []
  private queued: Response<T>[] = []
  private waiting: Waiter<T>[] = []
  private sticky: Response<T> | undefined

  /** Answer the oldest waiting request, or queue the answer for the next one. */
  push(...responses: Response<T>[]): void {
    for (const response of responses) {
      const waiter = this.waiting.shift()
      if (waiter) settle(waiter, response)
      else this.queued.push(response)
    }
  }

  /** Answer every request that finds nothing queued with this, until changed. */
  always(response: Response<T>): void {
    this.sticky = response
    for (const waiter of this.waiting.splice(0)) settle(waiter, response)
  }

  /** Requests still waiting for an answer. */
  get pending(): number {
    return this.waiting.length
  }

  request(args: Args, signal?: AbortSignal): Promise<T> {
    this.calls.push(args)
    return new Promise<T>((resolve, reject) => {
      throwIfAborted(signal)
      const next = this.queued.shift() ?? this.sticky
      if (next !== undefined) {
        settle({ resolve, reject }, next)
        return
      }
      const waiter = { resolve, reject }
      this.waiting.push(waiter)
      signal?.addEventListener(
        'abort',
        () => {
          this.waiting = this.waiting.filter((w) => w !== waiter)
          reject(signal.reason instanceof Error ? signal.reason : new DOMException('Aborted', 'AbortError'))
        },
        { once: true },
      )
    })
  }
}

function settle<T>(waiter: Waiter<T>, response: Response<T>): void {
  if (response instanceof Error) waiter.reject(response)
  else waiter.resolve(structuredClone(response))
}

export interface LogsCall {
  jobId: number
  after: number
  limit: number
}

export interface ScriptedApi {
  api: Api
  runs: Channel<ListRunsOptions | undefined, Run[]>
  run: Channel<number, RunDetail>
  logs: Channel<LogsCall, LogsResponse>
}

export function createScriptedApi(): ScriptedApi {
  const runs = new Channel<ListRunsOptions | undefined, Run[]>()
  const run = new Channel<number, RunDetail>()
  const logs = new Channel<LogsCall, LogsResponse>()
  const api: Api = {
    listRuns: (options, signal) => runs.request(options, signal),
    getRun: (runId, signal) => run.request(runId, signal),
    getLogs: (jobId, after, limit, signal) => logs.request({ jobId, after, limit }, signal),
  }
  return { api, runs, run, logs }
}
