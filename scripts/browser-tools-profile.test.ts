import { lstatSync, mkdtempSync, mkdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
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

  test('validates the source before changing the destination', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-missing-source-'));
    const destination = path.join(root, 'destination');
    mkdirSync(destination);
    writeFileSync(path.join(destination, 'profile-state'), 'keep me');

    expect(() => copyChromeProfile(path.join(root, 'missing'), destination)).toThrow();
    expect(readFileSync(path.join(destination, 'profile-state'), 'utf8')).toBe('keep me');
  });

  test('preserves a symlinked destination directory', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-destination-link-'));
    const source = path.join(root, 'source');
    const destinationTarget = path.join(root, 'destination-target');
    const destinationLink = path.join(root, 'destination-link');
    mkdirSync(source);
    mkdirSync(destinationTarget);
    writeFileSync(path.join(source, 'new-state'), 'new');
    writeFileSync(path.join(destinationTarget, 'old-state'), 'old');
    symlinkSync('destination-target', destinationLink);

    copyChromeProfile(source, destinationLink);

    expect(lstatSync(destinationLink).isSymbolicLink()).toBe(true);
    expect(readlinkSync(destinationLink)).toBe('destination-target');
    expect(readFileSync(path.join(destinationTarget, 'new-state'), 'utf8')).toBe('new');
    expect(() => readFileSync(path.join(destinationTarget, 'old-state'), 'utf8')).toThrow();
  });

  test('replaces a symlink to a non-directory without changing its target', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'browser-tools-profile-destination-file-link-'));
    const source = path.join(root, 'source');
    const destinationTarget = path.join(root, 'destination-target');
    const destinationLink = path.join(root, 'destination-link');
    mkdirSync(source);
    writeFileSync(path.join(source, 'new-state'), 'new');
    writeFileSync(destinationTarget, 'keep target');
    symlinkSync('destination-target', destinationLink);

    copyChromeProfile(source, destinationLink);

    expect(lstatSync(destinationLink).isDirectory()).toBe(true);
    expect(readFileSync(destinationTarget, 'utf8')).toBe('keep target');
    expect(readFileSync(path.join(destinationLink, 'new-state'), 'utf8')).toBe('new');
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
