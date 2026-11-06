import { describe, expect, test } from 'bun:test';
import { readConsoleHandle } from './browser-tools';

describe('readConsoleHandle', () => {
  test('releases the handle after copying its value', async () => {
    let disposed = false;
    const value = await readConsoleHandle({
      async jsonValue() {
        return { ok: true };
      },
      async dispose() {
        disposed = true;
      },
    });
    expect(value).toEqual({ ok: true });
    expect(disposed).toBe(true);
  });

  test('releases the handle when jsonValue throws', async () => {
    let disposed = false;
    await expect(
      readConsoleHandle({
        async jsonValue() {
          throw new Error('circular');
        },
        async dispose() {
          disposed = true;
        },
      }),
    ).rejects.toThrow('circular');
    expect(disposed).toBe(true);
  });
});
