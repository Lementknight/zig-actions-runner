import { memo, useMemo } from 'react'
import type { LogLine as LogLineData } from '../api'
import { isStyled, parseAnsi, type AnsiSegment } from '../lib/ansi'
import './LogLine.css'

/**
 * One log line (R7, R8): a per step line number in the gutter, the timestamp when the
 * viewer asked for it, and the text as styled spans. Memoized and keyed by seq by its
 * parent, so a tail of a thousand lines re-renders only the new ones.
 */
export const LogLine = memo(function LogLine({
  line,
  number,
  showTimestamp,
}: {
  line: LogLineData
  number: number
  showTimestamp: boolean
}) {
  const segments = useMemo(() => parseAnsi(line.line), [line.line])
  return (
    <div className="ar-log-line" data-seq={line.seq} data-stream={line.stream}>
      <span className="ar-log-line__number" aria-hidden>
        {number}
      </span>
      {showTimestamp && (
        <time className="ar-log-line__ts" dateTime={line.ts}>
          {line.ts}
        </time>
      )}
      <span className="ar-log-line__text">
        {segments.map((segment, i) => (
          <Segment key={i} segment={segment} />
        ))}
      </span>
    </div>
  )
})

/** Plain text stays text; only styled runs get a span, with the 16 colors named for CSS. */
function Segment({ segment }: { segment: AnsiSegment }) {
  if (!isStyled(segment)) return segment.text
  return (
    <span
      className="ar-ansi"
      data-fg={segment.fg}
      data-bg={segment.bg}
      data-bold={segment.bold ? '' : undefined}
      data-dim={segment.dim ? '' : undefined}
      data-italic={segment.italic ? '' : undefined}
      data-underline={segment.underline ? '' : undefined}
      data-strikethrough={segment.strikethrough ? '' : undefined}
      style={segment.fgRgb || segment.bgRgb ? { color: segment.fgRgb, backgroundColor: segment.bgRgb } : undefined}
    >
      {segment.text}
    </span>
  )
}
