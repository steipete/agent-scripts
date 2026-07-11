import { mkdtempSync, mkdirSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, test } from 'bun:test';
import { copyChromeProfile } from './browser-tools-profile';

describe('copyChromeProfile', () => {
  test('preserves relative symlink targets', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-'));
    const source = path.join(root, 'source');
    const destination = path.join(root, 'destination');
    mkdirSync(source);
    writeFileSync(path.join(source, 'target'), 'profile state');
    symlinkSync('target', path.join(source, 'relative-link'));

    copyChromeProfile(source, destination);

    expect(readlinkSync(path.join(destination, 'relative-link'))).toBe('target');
  });
});
