import { AlertIcon } from '@primer/octicons-react'
import type { ReactNode } from 'react'
import './RetryNotice.css'

/**
 * A request failed and the view is retrying on its own (R17). Sits above content that stays on
 * screen, so it says what is shown and that no action is needed. `children` replaces the
 * default text when a view has something more specific to say.
 */
export function RetryNotice({ children }: { children?: ReactNode }) {
  return (
    <div className="ar-retry-notice" role="status">
      <AlertIcon size={16} aria-hidden />
      <span>{children ?? "Can't reach the server. Showing the last data loaded and retrying."}</span>
    </div>
  )
}
