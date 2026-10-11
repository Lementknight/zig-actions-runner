import { HOUR, ansi, every, setUpJobLines, type FakeRun } from './spec'

/** A finished, green push run with three jobs (AE4). */
export const successRun: FakeRun = {
  id: 9101,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'CI',
  event: 'push',
  branch: 'main',
  sha: '3f9c2e18b7a4d6015c9e2f7a1b8d3c4e5f607182',
  createdMs: -26 * HOUR,
  jobs: [
    {
      id: 9201,
      name: 'build',
      runnerName: 'zig-runner-01',
      startMs: 4_000,
      steps: [
        { name: 'Set up job', durationMs: 1_000, lines: setUpJobLines('zig-runner-01') },
        { name: 'Run actions/checkout', durationMs: 2_000, lines: every(300, ['Syncing repository: Lementknight/zig-actions-runner', 'HEAD is now at 3f9c2e1']) },
        {
          name: 'Run zig build',
          durationMs: 41_000,
          lines: every(4_000, [
            ansi.gray('zig build -Doptimize=ReleaseSmall'),
            `${ansi.cyan('[1/4]')} Compile runner`,
            `${ansi.cyan('[2/4]')} Compile dagger driver`,
            `${ansi.cyan('[3/4]')} Compile log sink`,
            `${ansi.cyan('[4/4]')} Link zig-out/bin/runner`,
            ansi.green('Build succeeded in 39.2s'),
          ]),
        },
        { name: 'Complete job', durationMs: 500, lines: every(100, ['Cleaning up orphan processes']) },
      ],
    },
    {
      id: 9202,
      name: 'test',
      runnerName: 'zig-runner-02',
      startMs: 4_500,
      steps: [
        { name: 'Set up job', durationMs: 1_000, lines: setUpJobLines('zig-runner-02') },
        { name: 'Run actions/checkout', durationMs: 2_000, lines: every(300, ['HEAD is now at 3f9c2e1']) },
        {
          name: 'Run zig build test',
          durationMs: 72_000,
          lines: every(5_000, [
            ansi.gray('zig build test --summary all'),
            `jitconfig: decode ${ansi.green('OK')}`,
            `jitconfig: reject bad base64 ${ansi.green('OK')}`,
            `broker: parse AgentJobRequestMessage ${ansi.green('OK')}`,
            `broker: RunnerSessionInvalid retries ${ansi.green('OK')}`,
            `sink: flush by size ${ansi.green('OK')}`,
            `sink: flush by interval ${ansi.green('OK')}`,
            `dagger: run step maps to withExec ${ansi.green('OK')}`,
            ansi.bold(ansi.green('All 7 tests passed.')),
          ]),
        },
        { name: 'Complete job', durationMs: 500, lines: every(100, ['Cleaning up orphan processes']) },
      ],
    },
    {
      id: 9203,
      name: 'lint',
      runnerName: 'zig-runner-03',
      startMs: 5_000,
      steps: [
        { name: 'Set up job', durationMs: 1_000, lines: setUpJobLines('zig-runner-03') },
        { name: 'Run actions/checkout', durationMs: 2_000, lines: every(300, ['HEAD is now at 3f9c2e1']) },
        { name: 'Run zig fmt --check .', durationMs: 3_000, lines: every(1_000, [ansi.gray('zig fmt --check .'), 'All files formatted.']) },
        { name: 'Complete job', durationMs: 500, lines: every(100, ['Cleaning up orphan processes']) },
      ],
    },
  ],
}
