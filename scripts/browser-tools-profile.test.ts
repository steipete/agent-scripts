import { mkdtempSync, mkdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { describe, expect, test } from 'bun:test';
import { copyChromeProfile, isMainModule } from './browser-tools';

describe('copyChromeProfile', () => {
  test('preserves relative symlink targets', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-'));
    const source = path.join(root, 'source');
    const sourceLink = path.join(root, 'source-link');
    const destination = path.join(root, 'destination');
    mkdirSync(source);
    writeFileSync(path.join(source, 'target'), 'profile state');
    symlinkSync('target', path.join(source, 'relative-link'));
    symlinkSync('source', sourceLink);

    copyChromeProfile(sourceLink, destination);

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

describe('isMainModule', () => {
  test('falls back to canonical paths when import.meta.main is unavailable', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-main-module-'));
    const modulePath = path.join(root, 'browser-tools.ts');
    const launcherPath = path.join(root, 'browser-tools');
    writeFileSync(modulePath, 'fixture');
    symlinkSync('browser-tools.ts', launcherPath);

    expect(isMainModule(null, launcherPath, pathToFileURL(modulePath).href)).toBe(true);
    expect(isMainModule(null, path.join(root, 'other'), pathToFileURL(modulePath).href)).toBe(false);
  });
});
