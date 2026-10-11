import { ansi, every, setUpJobLines, type FakeRun } from './spec'

const compileLines = [
  ansi.gray('zig build -Doptimize=ReleaseSmall --summary all'),
  ...['config', 'jitconfig', 'auth', 'broker', 'dagger', 'sink', 'postgres', 'main'].flatMap((unit, i) => [
    `${ansi.cyan(`[${i + 1}/8]`)} Compile ${unit}.zig`,
    ansi.gray(`  ${unit}.zig: ok`),
  ]),
  `${ansi.cyan('Link')} zig-out/bin/runner`,
  ansi.green('Build Summary: 9/9 steps succeeded'),
]

/**
 * The demo run (F1). Created a few seconds after the app opens, so it appears at the top of
 * the run list, sits queued for a moment, then releases about two lines a second until the
 * job goes green. Step 2 prints nothing, and step 4's first lines arrive before its row (R18).
 * Reload the page to replay it.
 */
export const inProgressRun: FakeRun = {
  id: 9105,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'CI',
  event: 'push',
  branch: 'main',
  sha: '5b8e0f3a9c7d1e2468ace0bdf13579a2c4e6f801',
  createdMs: 3_000,
  jobs: [
    {
      id: 9206,
      name: 'build',
      runnerName: 'zig-runner-01',
      startMs: 3_000,
      steps: [
        { name: 'Set up job', durationMs: 1_500, lines: setUpJobLines('zig-runner-01') },
        { name: 'Run actions/checkout', durationMs: 1_500 },
        { name: 'Run zig build', durationMs: 10_000, lines: every(500, compileLines) },
        {
          name: 'Run echo hello && sleep 2 && echo done',
          durationMs: 3_000,
          rowDelayMs: 1_500,
          lines: [
            { atMs: 0, text: 'hello' },
            { atMs: 2_000, text: 'done' },
          ],
        },
        { name: 'Complete job', durationMs: 1_000, lines: every(300, ['Cleaning up orphan processes', 'Job completed']) },
      ],
    },
  ],
}
