import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'bun:test';

function loadReadClassName(): (className: unknown) => string {
  const source = readFileSync(new URL('./browser-tools.ts', import.meta.url), 'utf8');
  const start = source.indexOf('const readClassName = (className: unknown): string => {');
  const end = source.indexOf('const serialize = (el: HTMLElement)', start);
  if (start < 0 || end < 0) {
    throw new Error('readClassName is missing from the picker overlay');
  }
  const js = new Bun.Transpiler({ loader: 'ts' }).transformSync(source.slice(start, end));
  return new Function(`${js}; return readClassName;`)() as (className: unknown) => string;
}

describe('picker class name', () => {
  const readClassName = loadReadClassName();

  test('reads an SVGAnimatedString without calling trim on the object', () => {
    const svgClass = { baseVal: 'icon active', animVal: 'icon active' };
    expect(() => (svgClass as { trim: () => string }).trim()).toThrow(TypeError);
    expect(readClassName(svgClass)).toBe('icon active');
    expect(`.${readClassName(svgClass).trim().split(/\s+/).join('.')}`).toBe('.icon.active');
  });

  test('keeps an HTML class string', () => {
    expect(readClassName('foo bar')).toBe('foo bar');
    expect(readClassName('')).toBe('');
    expect(readClassName(null)).toBe('');
  });
});
