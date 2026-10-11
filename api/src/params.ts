// Query and path parameters. Each parser returns the value, `undefined` when the parameter is
// absent or empty (`?repo=` means no filter), or throws BadRequest, which the app answers with 400.

export class BadRequest extends Error {}

const DIGITS = /^\d+$/

/** A positive integer id that fits a JS number exactly (every GitHub id does). */
export function parseId(raw: string | undefined, name: string): number | undefined {
  if (raw === undefined || raw === '') return undefined
  const value = DIGITS.test(raw) ? Number(raw) : NaN
  if (!Number.isSafeInteger(value) || value < 1) throw new BadRequest(`invalid ${name}`)
  return value
}

/** A page size: `fallback` when absent, at least 1, and quietly capped at `max`. */
export function parseLimit(raw: string | undefined, fallback: number, max: number): number {
  if (raw === undefined || raw === '') return fallback
  const value = DIGITS.test(raw) ? Number(raw) : NaN
  if (!Number.isSafeInteger(value) || value < 1) throw new BadRequest('invalid limit')
  return Math.min(value, max)
}

export function parseText(raw: string | undefined): string | undefined {
  return raw === undefined || raw === '' ? undefined : raw
}
