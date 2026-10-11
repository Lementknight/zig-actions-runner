/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** `fake` serves bundled fixtures, `http` calls the read API. Unset means `fake`. */
  readonly VITE_DATA_SOURCE?: 'fake' | 'http'
  /** Base URL of the read API when `VITE_DATA_SOURCE` is `http`. Defaults to `/api`. */
  readonly VITE_API_BASE_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
