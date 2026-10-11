# web

The runner's frontend (milestone M6): a run list, a run page and a job view with live logs,
built to read as GitHub Actions. React, TypeScript and Vite on Primer React. The plan is
`docs/plans/2026-10-11-1237-feat-m6-actions-frontend-plan.md`; the API it reads is
`docs/SPEC.md` §5.3.

## Run it

Node 20.19 or newer.

```sh
npm ci
npm run dev     # http://localhost:5173
npm test        # Vitest, run once
npm run build   # type check and bundle into dist/
```

With no configuration the app runs on bundled fake data, so it works before the API exists.
A demo run appears at the top of the run list a few seconds after the page loads and streams
its log; reload the page to replay it.

## Configuration

Two variables pick where the data comes from. Every `.env` file is gitignored at the repo
root, so set them in `web/.env.local` (see `.env.example`) or on the command line.

| Variable | Default | Meaning |
|---|---|---|
| `VITE_DATA_SOURCE` | `fake` | `fake` serves the bundled fixtures in `src/api/fixtures/`. `http` calls the read API. |
| `VITE_API_BASE_URL` | `/api` | Base URL of the read API when the source is `http`. |
| `API_PROXY_TARGET` | `http://localhost:8080` | Dev server only: where `npm run dev` forwards `/api` requests. Never reaches the browser. |

Only names starting with `VITE_` are built into the browser bundle, so never put a secret in one.

## Run against the real API

Start the read API, then:

```sh
VITE_DATA_SOURCE=http API_PROXY_TARGET=http://localhost:8080 npm run dev
```

The browser asks the dev server for `/api/...` and the dev server forwards it to the API, so
there is no cross origin setup. To call an API on another host directly instead, set
`VITE_API_BASE_URL` to its full URL; that API must then allow cross origin requests.

No view changes between the two sources: everything goes through the `Api` interface in
`src/api/Api.ts`, with `fakeApi.ts` and `httpApi.ts` behind it, chosen in `src/api/index.ts`.

## Check the API against the contract

`src/api/contract.test.ts` asserts the behaviour the frontend relies on: gapless `seq` from 1,
`limit` and `next_after` paging, `job_done` on the final empty page, and 404 for unknown ids.
It always runs against the fake. To run it against the real API as well:

```sh
CONTRACT_API_URL=http://localhost:8080/api npm test
```

The API needs at least one completed job with three or more log lines. Checks marked
"proposed" in their name test answers the plan proposes to open SPEC questions, so a failure
there is a question for the team rather than a bug.

## Deep links in production

`npm run dev` serves the app for any path, so `/runs/12` reloads fine. A production server must
do the same and return `index.html` for every path outside `/api`. The Docker image below does.

## Docker

`Dockerfile` builds the app and serves it, with nothing but Docker on the host. Bun is used inside
the image only: it installs from `package-lock.json`, runs the same `npm run build` script (Vite
still bundles), and runs `server.ts`, a small `Bun.serve` server. Local development and CI stay
on npm.

```sh
docker build -t zig-runner-web web
docker run --rm -p 8080:3000 -e API_UPSTREAM=http://host.docker.internal:8081 zig-runner-web
# open http://localhost:8080
```

Build arguments, baked into the bundle (only `VITE_` names, so never a secret):

| Argument | Default in the image | Meaning |
|---|---|---|
| `VITE_DATA_SOURCE` | `http` | `http` reads the API; `fake` builds the demo with bundled fixtures. |
| `VITE_API_BASE_URL` | `/api` | Leave as `/api` so the browser calls the server, which proxies it. |
| `BUN_VERSION` | `1.3.14` | The `oven/bun` tag for both stages. |

For example `docker build --build-arg VITE_DATA_SOURCE=fake -t zig-runner-web-demo web` gives an
image that needs no API.

Runtime environment, read when the container starts:

| Variable | Default | Meaning |
|---|---|---|
| `API_UPSTREAM` | none | Base URL of the read API, such as `http://api:8080`. `/api/...` is forwarded to it unchanged (path and query kept). Unset or unreachable answers `502`; no answer within 30 s answers `504`. |
| `PORT` | `3000` | Port the server listens on inside the container. |

What the server answers: a file in `dist/` when one matches (fingerprinted `/assets/` files are
cached for a year, everything else revalidates), `404` for a missing `/assets/` file, and
`index.html` for every other path, so deep links like `/runs/1/jobs/2` load the app. The image
runs as the `bun` user, not root, and stops at once on `docker stop`. `.dockerignore` keeps
`node_modules`, `dist` and every `.env` file out of the build.
