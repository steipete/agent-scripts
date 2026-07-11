import { cpSync, mkdirSync, rmSync } from 'node:fs';

export function copyChromeProfile(sourceDir: string, profileDir: string): void {
  rmSync(profileDir, { recursive: true, force: true });
  mkdirSync(profileDir, { recursive: true });
  cpSync(sourceDir, profileDir, {
    recursive: true,
    force: true,
    verbatimSymlinks: true,
  });
}
