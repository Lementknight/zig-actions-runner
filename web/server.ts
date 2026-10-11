// Production server for the web image (Dockerfile): serves the Vite build in dist/, answers every
// path outside /api with index.html so deep links such as /runs/1/jobs/2 load the app, and proxies
// /api/* unchanged to API_UPSTREAM (for example http://api:8080). Runs on Bun only.
import { stat } from 'node:fs/promises'
import { resolve, sep } from 'node:path'

const root = resolve(process.env.STATIC_DIR ?? 'dist')
const indexHtml = resolve(root, 'index.html')
const upstream = (process.env.API_UPSTREAM ?? '').replace(/\/+$/, '')
const port = Number(process.env.PORT ?? 3000)
const upstreamTimeoutMs = 30_000

// Hop-by-hop headers never cross a proxy; content-encoding and -length are dropped from responses
// because Bun's fetch has already decompressed the body.
const hopByHop = ['connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'proxy-connection', 'te', 'trailer']

function text(status: number, body: string): Response {
  return new Response(body + '\n', { status, headers: { 'content-type': 'text/plain; charset=utf-8' } })
}

async function proxy(req: Request, url: URL): Promise<Response> {
  if (!upstream) return text(502, 'API_UPSTREAM is not set')
  const headers = new Headers(req.headers)
  for (const h of [...hopByHop, 'host']) headers.delete(h)
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD'
  try {
    const res = await fetch(upstream + url.pathname + url.search, {
      method: req.method,
      headers,
      body: hasBody ? req.body : undefined,
      redirect: 'manual',
      signal: AbortSignal.timeout(upstreamTimeoutMs),
    })
    const out = new Headers(res.headers)
    for (const h of [...hopByHop, 'content-encoding', 'content-length']) out.delete(h)
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers: out })
  } catch (e) {
    const timedOut = e instanceof DOMException && e.name === 'TimeoutError'
    return timedOut ? text(504, 'API upstream timed out') : text(502, 'API upstream unavailable')
  }
}

/** The file under dist/ a path names, or null for a missing file, a directory or an escape. */
async function staticFile(pathname: string): Promise<string | null> {
  let decoded: string
  try {
    decoded = decodeURIComponent(pathname)
  } catch {
    return null
  }
  const file = resolve(root, '.' + decoded)
  if (!file.startsWith(root + sep)) return null
  try {
    return (await stat(file)).isFile() ? file : null
  } catch {
    return null
  }
}

const server = Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url)
    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) return proxy(req, url)
    if (req.method !== 'GET' && req.method !== 'HEAD') return text(405, 'method not allowed')

    const file = await staticFile(url.pathname)
    if (file) {
      // Vite fingerprints everything under assets/, so those never change under a name.
      const immutable = url.pathname.startsWith('/assets/')
      return new Response(Bun.file(file), {
        headers: { 'cache-control': immutable ? 'public, max-age=31536000, immutable' : 'no-cache' },
      })
    }
    // A missing fingerprinted asset (a tab still holding an old build) must not get HTML back.
    if (url.pathname.startsWith('/assets/')) return text(404, 'not found')
    // Every other path is a route of the app.
    return new Response(Bun.file(indexHtml), {
      headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-cache' },
    })
  },
})

console.log(`web: serving ${root} on :${server.port}, /api -> ${upstream || '(API_UPSTREAM not set)'}`)

// As PID 1 in a container nothing handles SIGTERM unless we do, and docker stop would wait 10 s.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    server.stop()
    process.exit(0)
  })
}
