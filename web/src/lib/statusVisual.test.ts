import { describe, expect, it } from 'vitest'
import { statusVisual } from './statusVisual'

describe('statusVisual', () => {
  it.each([
    ['completed', 'success', 'check-circle-fill', '--ar-status-success', 'Success'],
    ['completed', 'failure', 'x-circle-fill', '--ar-status-failure', 'Failure'],
    ['completed', 'cancelled', 'stop', '--ar-status-cancelled', 'Cancelled'],
    ['completed', 'skipped', 'skip', '--ar-status-skipped', 'Skipped'],
    ['in_progress', null, 'spinner', '--ar-status-in-progress', 'In progress'],
    ['queued', null, 'dot-fill', '--ar-status-queued', 'Queued'],
  ])('%s with %s draws %s', (status, conclusion, icon, colorToken, label) => {
    expect(statusVisual(status, conclusion)).toMatchObject({ icon, colorToken, label })
  })

  it('ignores a conclusion on a run that has not completed', () => {
    expect(statusVisual('in_progress', 'failure').kind).toBe('in_progress')
  })

  it('falls back to neutral with the raw label for completed and a null conclusion', () => {
    expect(statusVisual('completed', null)).toEqual({
      kind: 'neutral',
      icon: 'question',
      colorToken: '--ar-status-neutral',
      label: 'completed',
    })
  })

  it('falls back to neutral with the raw label for an unknown status', () => {
    expect(statusVisual('waiting', null)).toMatchObject({ kind: 'neutral', icon: 'question', label: 'waiting' })
  })

  it('falls back to neutral with the raw label for an unknown conclusion', () => {
    expect(statusVisual('completed', 'timed_out')).toMatchObject({ kind: 'neutral', label: 'timed_out' })
  })
})
