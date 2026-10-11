import Anser from 'anser'

// ANSI escapes to styled segments (KTD5, R7). anser does the parsing and hands back JSON;
// this module turns its class names into data a React component can render as spans. No
// HTML string is produced anywhere, so log text can never run as markup.

/** The 16 basic colors. Each one has an --ar-ansi-* token, so a restyle can recolor logs. */
export type AnsiNamedColor =
  | 'black'
  | 'red'
  | 'green'
  | 'yellow'
  | 'blue'
  | 'magenta'
  | 'cyan'
  | 'white'
  | 'bright-black'
  | 'bright-red'
  | 'bright-green'
  | 'bright-yellow'
  | 'bright-blue'
  | 'bright-magenta'
  | 'bright-cyan'
  | 'bright-white'

export interface AnsiSegment {
  text: string
  /** One of the 16 named colors; LogLine.css maps it to its token. */
  fg?: AnsiNamedColor
  bg?: AnsiNamedColor
  /** A 256 color or truecolor value, `rgb(r g b)`, used inline when the color has no token. */
  fgRgb?: string
  bgRgb?: string
  bold?: boolean
  dim?: boolean
  italic?: boolean
  underline?: boolean
  strikethrough?: boolean
}

const NAMED: ReadonlySet<string> = new Set<AnsiNamedColor>([
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'bright-black',
  'bright-red',
  'bright-green',
  'bright-yellow',
  'bright-blue',
  'bright-magenta',
  'bright-cyan',
  'bright-white',
])

const PALETTE_BASIC: AnsiNamedColor[] = [
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'bright-black',
  'bright-red',
  'bright-green',
  'bright-yellow',
  'bright-blue',
  'bright-magenta',
  'bright-cyan',
  'bright-white',
]

/** The xterm 256 color palette above the first 16: a 6x6x6 cube, then 24 grays. */
export function paletteRgb(index: number): string {
  if (index >= 232) {
    const gray = 8 + (index - 232) * 10
    return `rgb(${gray} ${gray} ${gray})`
  }
  const i = index - 16
  const level = (v: number) => (v === 0 ? 0 : 55 + v * 40)
  const r = level(Math.floor(i / 36))
  const g = level(Math.floor(i / 6) % 6)
  const b = level(i % 6)
  return `rgb(${r} ${g} ${b})`
}

type Color = { named?: AnsiNamedColor; rgb?: string }

/**
 * anser's class name for a color: `ansi-red`, `ansi-bright-red`, `ansi-palette-208`, or
 * `ansi-truecolor` with the channels in a separate field. The truecolor field is only read
 * when the class says so, because anser leaves the previous value in it otherwise.
 */
function color(className: string | null, truecolor: string | null): Color {
  if (!className) return {}
  const name = className.replace(/^ansi-/, '')
  if (NAMED.has(name)) return { named: name as AnsiNamedColor }
  if (name === 'truecolor' && truecolor) {
    const [r, g, b] = truecolor.split(',').map((c) => Number(c.trim()))
    return { rgb: `rgb(${r} ${g} ${b})` }
  }
  const palette = /^palette-(\d+)$/.exec(name)
  if (palette) {
    const index = Number(palette[1])
    if (index < 16) return { named: PALETTE_BASIC[index] }
    if (index < 256) return { rgb: paletteRgb(index) }
  }
  return {}
}

/**
 * The styled segments of one log line. Color state starts fresh for every line, as GitHub
 * renders it, so an unclosed escape on one line never bleeds into the next.
 */
export function parseAnsi(line: string): AnsiSegment[] {
  const entries = Anser.ansiToJson(line, { json: true, remove_empty: true, use_classes: true })
  const segments: AnsiSegment[] = []
  for (const entry of entries) {
    const fg = color(entry.fg, entry.fg_truecolor)
    const bg = color(entry.bg, entry.bg_truecolor)
    const segment: AnsiSegment = { text: entry.content }
    if (fg.named) segment.fg = fg.named
    if (fg.rgb) segment.fgRgb = fg.rgb
    if (bg.named) segment.bg = bg.named
    if (bg.rgb) segment.bgRgb = bg.rgb
    for (const decoration of entry.decorations) {
      if (decoration === 'bold') segment.bold = true
      else if (decoration === 'dim') segment.dim = true
      else if (decoration === 'italic') segment.italic = true
      else if (decoration === 'underline') segment.underline = true
      else if (decoration === 'strikethrough') segment.strikethrough = true
    }
    segments.push(segment)
  }
  return segments
}

/** True when a segment carries any styling, so plain text can skip the span. */
export function isStyled(segment: AnsiSegment): boolean {
  return Boolean(
    segment.fg ||
      segment.bg ||
      segment.fgRgb ||
      segment.bgRgb ||
      segment.bold ||
      segment.dim ||
      segment.italic ||
      segment.underline ||
      segment.strikethrough,
  )
}
