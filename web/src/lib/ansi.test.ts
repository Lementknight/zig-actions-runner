import { describe, expect, it } from 'vitest'
import { isStyled, paletteRgb, parseAnsi } from './ansi'

const ESC = '\u001b'

describe('parseAnsi', () => {
  it('returns plain text as one unstyled segment', () => {
    const segments = parseAnsi('zig build -Doptimize=ReleaseSmall')
    expect(segments).toEqual([{ text: 'zig build -Doptimize=ReleaseSmall' }])
    expect(isStyled(segments[0])).toBe(false)
  })

  it('returns no segments for an empty line', () => {
    expect(parseAnsi('')).toEqual([])
  })

  it('maps the 16 basic colors to names, not values', () => {
    const segments = parseAnsi(`${ESC}[31merror:${ESC}[0m plain ${ESC}[90mgray${ESC}[0m`)
    expect(segments).toEqual([
      { text: 'error:', fg: 'red' },
      { text: ' plain ' },
      { text: 'gray', fg: 'bright-black' },
    ])
  })

  it('keeps bold and the other decorations', () => {
    const segments = parseAnsi(`${ESC}[1;32mAll 7 tests passed.${ESC}[0m ${ESC}[4mu${ESC}[0m`)
    expect(segments[0]).toEqual({ text: 'All 7 tests passed.', fg: 'green', bold: true })
    expect(segments[2]).toEqual({ text: 'u', underline: true })
  })

  it('maps background colors too', () => {
    expect(parseAnsi(`${ESC}[41mon red${ESC}[0m`)).toEqual([{ text: 'on red', bg: 'red' }])
  })

  it('falls back to inline rgb for 256 color and truecolor', () => {
    const segments = parseAnsi(`${ESC}[38;5;208mwarm${ESC}[0m ${ESC}[38;2;10;20;30mexact${ESC}[0m`)
    expect(segments[0]).toEqual({ text: 'warm', fgRgb: 'rgb(255 135 0)' })
    expect(segments[2]).toEqual({ text: 'exact', fgRgb: 'rgb(10 20 30)' })
  })

  it('maps the first 16 palette entries to their names', () => {
    expect(parseAnsi(`${ESC}[38;5;1mred${ESC}[0m`)).toEqual([{ text: 'red', fg: 'red' }])
    expect(parseAnsi(`${ESC}[38;5;12mblue${ESC}[0m`)).toEqual([{ text: 'blue', fg: 'bright-blue' }])
  })

  it('does not let a truecolor value leak into a later named color on the same line', () => {
    const segments = parseAnsi(`${ESC}[38;2;10;20;30mtrue${ESC}[0m ${ESC}[90mgray${ESC}[0m`)
    expect(segments[2]).toEqual({ text: 'gray', fg: 'bright-black' })
  })

  it('starts every line with no color, even after an unclosed escape', () => {
    parseAnsi(`${ESC}[31mstill red`)
    expect(parseAnsi('next line')).toEqual([{ text: 'next line' }])
  })

  it('leaves markup characters as text', () => {
    expect(parseAnsi('<script>alert(1)</script>')).toEqual([{ text: '<script>alert(1)</script>' }])
  })
})

describe('paletteRgb', () => {
  it('builds the color cube and the gray ramp', () => {
    expect(paletteRgb(16)).toBe('rgb(0 0 0)')
    expect(paletteRgb(231)).toBe('rgb(255 255 255)')
    expect(paletteRgb(232)).toBe('rgb(8 8 8)')
    expect(paletteRgb(255)).toBe('rgb(238 238 238)')
  })
})
