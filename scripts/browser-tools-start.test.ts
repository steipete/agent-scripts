import { spawn } from 'node:child_process';
import { describe, expect, test } from 'bun:test';
import { killDetachedProcess, waitForDevtools } from './browser-tools';

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

describe('waitForDevtools', () => {
  test('stops a detached process when DevTools never accepts', async () => {
    const child = spawn('sleep', ['30'], { detached: true, stdio: 'ignore' });
    const pid = child.pid ?? 0;
    child.unref();
    expect(processAlive(pid)).toBe(true);

    const connected = await waitForDevtools({
      attempts: 2,
      sleep: async () => {},
      connect: async () => {
        throw new Error('connection refused');
      },
      kill: () => killDetachedProcess(pid),
    });

    expect(connected).toBe(false);
    let gone = false;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      if (!processAlive(pid)) {
        gone = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    expect(gone).toBe(true);
  });

  test('leaves the process alone once DevTools accepts', async () => {
    let killed = 0;
    let disconnects = 0;
    const connected = await waitForDevtools({
      attempts: 3,
      sleep: async () => {},
      connect: async () => ({
        disconnect: async () => {
          disconnects += 1;
        },
      }),
      kill: () => {
        killed += 1;
      },
    });

    expect(connected).toBe(true);
    expect(disconnects).toBe(1);
    expect(killed).toBe(0);
  });

  test('ignores a missing pid', () => {
    expect(() => killDetachedProcess(undefined)).not.toThrow();
  });
});
