import { mkdtempSync, mkdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, test } from 'bun:test';
import { copyChromeProfile } from './browser-tools';

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

  test('rejects overlapping source and destination paths', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-overlap-'));
    const source = path.join(root, 'source');
    mkdirSync(source);
    writeFileSync(path.join(source, 'profile-state'), 'keep me');

    expect(() => copyChromeProfile(source, source)).toThrow('must not overlap');
    expect(() => copyChromeProfile(source, path.join(source, 'nested'))).toThrow('must not overlap');
    expect(() => copyChromeProfile(source, root)).toThrow('must not overlap');
    expect(readFileSync(path.join(source, 'profile-state'), 'utf8')).toBe('keep me');
  });
});
