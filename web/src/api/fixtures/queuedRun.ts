import { MINUTE, type FakeRun } from './spec'

/** A run no runner has picked up yet. It has no jobs, so it stays queued. */
export const queuedRun: FakeRun = {
  id: 9104,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'Nightly build',
  event: 'schedule',
  branch: 'main',
  sha: '3f9c2e18b7a4d6015c9e2f7a1b8d3c4e5f607182',
  createdMs: -2 * MINUTE,
  jobs: [],
}
