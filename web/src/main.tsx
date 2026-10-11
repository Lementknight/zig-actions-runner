import { BaseStyles, ThemeProvider } from '@primer/react'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

// Order matters: Primer's primitives and light theme define the variables that
// tokens.css aliases, and global.css reads only the aliases.
import '@primer/primitives/dist/css/primitives.css'
import '@primer/primitives/dist/css/functional/themes/light.css'
import './styles/tokens.css'
import './styles/global.css'

import { ApiProvider, createApi } from './api'
import App from './App.tsx'

// One Api for the page's lifetime; the fake's clock starts here.
const api = createApi()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider colorMode="day">
      <BaseStyles>
        <ApiProvider api={api}>
          <App />
        </ApiProvider>
      </BaseStyles>
    </ThemeProvider>
  </StrictMode>,
)
