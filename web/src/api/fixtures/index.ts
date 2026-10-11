import { cancelledRun } from './cancelledRun'
import { failedRun } from './failedRun'
import { inProgressRun } from './inProgressRun'
import { queuedRun } from './queuedRun'
import { successRun } from './successRun'
import type { FakeRun, FakeRunner } from './spec'

/** Every bundled fake run (R10). */
export const defaultFixtures: FakeRun[] = [successRun, failedRun, cancelledRun, queuedRun, inProgressRun]

/** Runners that never appear in a fixture job: one waiting for work, one that has stopped. */
export const defaultExtraRunners: FakeRunner[] = [{ name: 'zig-runner-04' }, { name: 'zig-runner-05', offline: true }]
