import { ArrowDownIcon } from '@primer/octicons-react'
import './JobToolbar.css'

/**
 * The log's controls (R8 and the tail): a timestamps switch in the job header, and a
 * "Jump to bottom" button that floats in while new lines arrive and the viewer has
 * scrolled away from them.
 */
export function JobToolbar({
  showTimestamps,
  onToggleTimestamps,
  showJump,
  onJump,
}: {
  showTimestamps: boolean
  onToggleTimestamps: () => void
  showJump: boolean
  onJump: () => void
}) {
  return (
    <>
      <div className="ar-job-toolbar">
        <span className="ar-job-toolbar__label" id="ar-timestamps-label">
          Show timestamps
        </span>
        <button
          type="button"
          role="switch"
          aria-checked={showTimestamps}
          aria-labelledby="ar-timestamps-label"
          className="ar-switch"
          onClick={onToggleTimestamps}
        >
          <span className="ar-switch__knob" />
        </button>
      </div>
      {showJump && (
        <button type="button" className="ar-jump" onClick={onJump}>
          <ArrowDownIcon size={16} aria-hidden />
          Jump to bottom
        </button>
      )}
    </>
  )
}
