import { serve } from '@hono/node-server'
import { createApp } from './app'
import { createPool } from './db'

// Entry point: `npm start`. DATABASE_URL is required and never printed (SPEC §9); PORT defaults to 8080.

const databaseUrl = process.env.DATABASE_URL
if (!databaseUrl) {
  console.error('DATABASE_URL is not set')
  process.exit(1)
}

const port = Number(process.env.PORT ?? 8080)
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  console.error(`PORT must be a port number, got ${process.env.PORT}`)
  process.exit(1)
}

const pool = createPool(databaseUrl)
// An idle client that loses its connection emits here; without a listener Node would crash.
pool.on('error', (error) => console.error(`database pool error: ${error.message}`))

const server = serve({ fetch: createApp(pool).fetch, port }, (info) => {
  console.log(`api listening on http://localhost:${info.port}/api`)
})

function shutdown() {
  server.close()
  void pool.end()
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
