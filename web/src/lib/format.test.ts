import { describe, expect, it } from 'vitest'
import { elapsedSeconds, formatAge, formatDuration, runDurationSeconds, shortSha } from './format'

describe('formatDuration', () => {
  it.each([
    [0, '0s'],
    [59, '59s'],
    [61, '1m 1s'],
    [3661, '1h 1m 1s'],
    [-5, '0s'],
    [59.9, '59s'],
  ])('%s seconds formats as %s', (seconds, text) => {
    expect(formatDuration(seconds)).toBe(text)
  })
})

describe('elapsedSeconds', () => {
  const now = Date.parse('2026-10-11T12:00:10Z')

  it('is null before the thing starts', () => {
    expect(elapsedSeconds(null, null, now)).toBeNull()
  })

  it('runs to now while not finished', () => {
    expect(elapsedSeconds('2026-10-11T12:00:00Z', null, now)).toBe(10)
  })

  it('runs to the end once finished', () => {
    expect(elapsedSeconds('2026-10-11T12:00:00Z', '2026-10-11T12:01:12Z', now)).toBe(72)
  })

  it('clamps an end before the start to zero', () => {
    expect(elapsedSeconds('2026-10-11T12:00:05Z', '2026-10-11T12:00:00Z', now)).toBe(0)
  })
})

describe('runDurationSeconds', () => {
  const now = Date.parse('2026-10-11T12:01:00Z')
  const created_at = '2026-10-11T12:00:00Z'

  it('counts from created_at to now while in progress', () => {
    expect(runDurationSeconds({ status: 'in_progress', created_at, completed_at: null }, now)).toBe(60)
  })

  it('counts from created_at to completed_at once completed', () => {
    expect(
      runDurationSeconds({ status: 'completed', created_at, completed_at: '2026-10-11T12:00:30Z' }, now),
    ).toBe(30)
  })

  it('is null while queued', () => {
    expect(runDurationSeconds({ status: 'queued', created_at, completed_at: null }, now)).toBeNull()
  })
})

describe('formatAge', () => {
  const now = Date.parse('2026-10-11T12:00:00Z')
  const ago = (seconds: number) => new Date(now - seconds * 1000).toISOString()

  it.each([
    [5, 'now'],
    [3 * 60, '3 minutes ago'],
    [2 * 3600, '2 hours ago'],
    [26 * 3600, 'yesterday'],
    [15 * 86400, '2 weeks ago'],
  ])('%s seconds ago reads %s', (seconds, text) => {
    expect(formatAge(ago(seconds), now)).toBe(text)
  })

  it('reads a time slightly in the future as now', () => {
    expect(formatAge(ago(-3), now)).toBe('now')
  })
})

describe('shortSha', () => {
  it('keeps the first seven characters', () => {
    expect(shortSha('3f9c2e18b7a4d6015c9e')).toBe('3f9c2e1')
  })

  it('is empty for a missing sha', () => {
    expect(shortSha(null)).toBe('')
  })
})
