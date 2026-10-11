import pg from 'pg'

// The one thing the routes need from Postgres. A pg Pool satisfies it, and so does the stub the
// unit tests pass in, so the routes never know which one they talk to.
export interface Queryable {
  query<R extends pg.QueryResultRow = pg.QueryResultRow>(text: string, params?: unknown[]): Promise<{ rows: R[] }>
}

// BIGINT (int8) arrives from pg as a string, because it can exceed 2^53. Every BIGINT here is a
// GitHub id or a log seq, far below that, and web/ expects JSON numbers, so parse them as numbers.
const INT8_OID = 20
const types: pg.CustomTypesConfig = {
  getTypeParser: ((oid: number, format?: string) =>
    oid === INT8_OID && format !== 'binary'
      ? (value: string) => Number(value)
      : pg.types.getTypeParser(oid, format as 'text')) as pg.CustomTypesConfig['getTypeParser'],
}

/**
 * A pool on DATABASE_URL whose every session is read-only (SPEC §4: only the runner writes).
 * `default_transaction_read_only` is set in the startup packet, so it holds before the first query.
 */
export function createPool(connectionString: string): pg.Pool {
  return new pg.Pool({
    connectionString,
    options: '-c default_transaction_read_only=on',
    types,
    max: 10,
    connectionTimeoutMillis: 5_000,
  })
}
