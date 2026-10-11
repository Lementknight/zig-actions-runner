import type { Api } from './Api'
import { createFakeApi } from './fakeApi'
import { createHttpApi } from './httpApi'

export type DataSource = 'fake' | 'http'

/** The data source named by VITE_DATA_SOURCE. Unset or empty means fake. */
export function dataSource(value: string | undefined = import.meta.env.VITE_DATA_SOURCE): DataSource {
  if (!value || value === 'fake') return 'fake'
  if (value === 'http') return 'http'
  throw new Error(`VITE_DATA_SOURCE must be "fake" or "http", not "${value}"`)
}

/** Base URL of the read API. Defaults to /api, which the dev server proxies (vite.config.ts). */
export function apiBaseUrl(value: string | undefined = import.meta.env.VITE_API_BASE_URL): string {
  return value || '/api'
}

/** The Api the app runs on (KTD2). Views never choose; they call useApi(). */
export function createApi(source: DataSource = dataSource()): Api {
  switch (source) {
    case 'fake':
      return createFakeApi()
    case 'http':
      return createHttpApi(apiBaseUrl())
  }
}

export { ApiError, isAbort, isNotFound, type Api } from './Api'
export { ApiProvider, useApi } from './ApiContext'
export type * from './types'
