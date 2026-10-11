import type { Api } from './Api'
import { createFakeApi } from './fakeApi'

export type DataSource = 'fake' | 'http'

/** The data source named by VITE_DATA_SOURCE. Unset or empty means fake. */
export function dataSource(value: string | undefined = import.meta.env.VITE_DATA_SOURCE): DataSource {
  if (!value || value === 'fake') return 'fake'
  if (value === 'http') return 'http'
  throw new Error(`VITE_DATA_SOURCE must be "fake" or "http", not "${value}"`)
}

/** The Api the app runs on (KTD2). Views never choose; they call useApi(). */
export function createApi(source: DataSource = dataSource()): Api {
  switch (source) {
    case 'fake':
      return createFakeApi()
    case 'http':
      // U7 adds httpApi(import.meta.env.VITE_API_BASE_URL || '/api') here.
      throw new Error('VITE_DATA_SOURCE=http needs the HTTP client, which is not built yet')
  }
}

export { ApiError, isAbort, isNotFound, type Api } from './Api'
export { ApiProvider, useApi } from './ApiContext'
export type * from './types'
