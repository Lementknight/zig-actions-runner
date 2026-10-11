import { cancelledRun } from './cancelledRun'
import { failedRun } from './failedRun'
import { inProgressRun } from './inProgressRun'
import { queuedRun } from './queuedRun'
import { successRun } from './successRun'
import type { FakeRun } from './spec'

/** Every bundled fake run (R10). */
export const defaultFixtures: FakeRun[] = [successRun, failedRun, cancelledRun, queuedRun, inProgressRun]
