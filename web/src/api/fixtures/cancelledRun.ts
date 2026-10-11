import { MINUTE, ansi, every, setUpJobLines, type FakeRun } from './spec'

/** A run cancelled partway through its build step. */
export const cancelledRun: FakeRun = {
  id: 9103,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'Release',
  event: 'workflow_dispatch',
  branch: 'release/v0.1',
  sha: 'c0ffee5d2b1a09f8e7d6c5b4a3928170f6e5d4c3',
  createdMs: -40 * MINUTE,
  jobs: [
    {
      id: 9205,
      name: 'release',
      runnerName: 'zig-runner-01',
      startMs: 2_000,
      steps: [
        { name: 'Set up job', durationMs: 1_000, lines: setUpJobLines('zig-runner-01') },
        { name: 'Run actions/checkout', durationMs: 2_000, lines: every(300, ['HEAD is now at c0ffee5']) },
        {
          name: 'Run zig build -Dtarget=x86_64-linux-musl',
          durationMs: 25_000,
          conclusion: 'cancelled',
          lines: [
            ...every(3_000, [ansi.gray('zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall'), `${ansi.cyan('[1/4]')} Compile runner`]),
            { atMs: 24_000, text: ansi.yellow('The operation was canceled.'), stream: 'stderr' },
          ],
        },
        { name: 'Publish release', durationMs: 0, conclusion: 'skipped' },
      ],
    },
  ],
}
