import { createContext, useContext, type ReactNode } from 'react'
import type { Api } from './Api'

// Views and hooks reach the Api through context, so tests pass a scripted one (KTD9).

const ApiContext = createContext<Api | null>(null)

export function ApiProvider({ api, children }: { api: Api; children: ReactNode }) {
  return <ApiContext.Provider value={api}>{children}</ApiContext.Provider>
}

export function useApi(): Api {
  const api = useContext(ApiContext)
  if (!api) throw new Error('useApi must be used inside an ApiProvider')
  return api
}
