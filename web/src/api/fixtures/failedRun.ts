import { HOUR, ansi, every, setUpJobLines, type FakeRun } from './spec'

/** A finished run whose test step fails on stderr, so the step after it is skipped. */
export const failedRun: FakeRun = {
  id: 9102,
  repo: 'Lementknight/zig-actions-runner',
  workflow: 'CI',
  event: 'pull_request',
  branch: 'feat/broker-session',
  sha: 'a7e1d09c4b3f28e65d1a0c9b8e7f6d5c4b3a2918',
  createdMs: -2 * HOUR,
  jobs: [
    {
      id: 9204,
      name: 'test',
      runnerName: 'zig-runner-02',
      startMs: 3_000,
      steps: [
        { name: 'Set up job', durationMs: 1_000, lines: setUpJobLines('zig-runner-02') },
        { name: 'Run actions/checkout', durationMs: 2_000, lines: every(300, ['HEAD is now at a7e1d09']) },
        {
          name: 'Run zig build test',
          durationMs: 18_000,
          conclusion: 'failure',
          lines: [
            ...every(2_000, [
              ansi.gray('zig build test --summary all'),
              `jitconfig: decode ${ansi.green('OK')}`,
              `broker: parse AgentJobRequestMessage ${ansi.green('OK')}`,
            ]),
            ...every(
              500,
              [
                `${ansi.red('error:')} 'broker.test.session refresh' failed:`,
                '    expected .RunnerSessionInvalid, found .Timeout',
                '    src/github/broker.zig:212:5: 0x10a3f2c in test.session refresh (test)',
                ansi.red('1 passed; 1 failed.'),
                `${ansi.red('error:')} the following test command failed with exit code 1`,
              ],
              { startMs: 8_000, stream: 'stderr' },
            ),
            { atMs: 11_000, text: ansi.red('Error: Process completed with exit code 1.'), stream: 'stderr' },
          ],
        },
        { name: 'Upload coverage', durationMs: 0, conclusion: 'skipped' },
        { name: 'Complete job', durationMs: 500, lines: every(100, ['Cleaning up orphan processes']) },
      ],
    },
  ],
}
