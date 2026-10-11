import { createApp } from '../src/app'
import type { Queryable } from '../src/db'

// Shared by the unit tests: a stub database and a request helper.

export interface Call {
  sql: string
  params: unknown[]
}

/** Answers each query with the first handler whose pattern matches its SQL, and records it. */
export function stubDb(handlers: [RegExp, (params: unknown[]) => unknown[]][] = []) {
  const calls: Call[] = []
  const db: Queryable = {
    async query(sql: string, params: unknown[] = []) {
      calls.push({ sql, params })
      const handler = handlers.find(([pattern]) => pattern.test(sql))
      return { rows: (handler ? handler[1](params) : []) as never[] }
    },
  }
  return { db, calls }
}

/** Requests `path` from an app on `db` and returns the status and parsed JSON body. */
export async function get(db: Queryable, path: string) {
  const response = await createApp(db).request(path)
  return { status: response.status, body: (await response.json()) as unknown }
}
