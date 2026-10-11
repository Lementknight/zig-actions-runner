import { Hono } from 'hono'
import type { Queryable } from './db'
import { BadRequest, parseId, parseLimit, parseText } from './params'
import { getRun, listRuns } from './queries'

// The read API, SPEC §5.3. Every route only reads; the pool it is given is read-only as well.

const RUNS_DEFAULT_LIMIT = 50
const RUNS_MAX_LIMIT = 200

export function createApp(db: Queryable): Hono {
  const app = new Hono().basePath('/api')

  app.get('/health', async (c) => {
    try {
      await db.query('SELECT 1')
      return c.json({ ok: true })
    } catch {
      return c.json({ ok: false, error: 'database unavailable' }, 503)
    }
  })

  app.get('/runs', async (c) => {
    const runs = await listRuns(db, {
      repo: parseText(c.req.query('repo')),
      limit: parseLimit(c.req.query('limit'), RUNS_DEFAULT_LIMIT, RUNS_MAX_LIMIT),
      before: parseId(c.req.query('before'), 'before'),
    })
    return c.json(runs)
  })

  app.get('/runs/:id', async (c) => {
    const id = parseId(c.req.param('id'), 'run id')!
    const run = await getRun(db, id)
    return run === null ? c.json({ error: 'not found' }, 404) : c.json(run)
  })

  app.notFound((c) => c.json({ error: 'not found' }, 404))

  app.onError((error, c) => {
    if (error instanceof BadRequest) return c.json({ error: error.message }, 400)
    // The message only: a pg error carries no credentials, and nothing else is worth echoing.
    console.error(`${c.req.method} ${c.req.path} failed: ${error.message}`)
    return c.json({ error: 'internal error' }, 500)
  })

  return app
}
