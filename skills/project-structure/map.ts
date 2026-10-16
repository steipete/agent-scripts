#!/usr/bin/env node
// project-structure: compress a TypeScript or Swift repository into a single symbol-map file
// that an LLM agent can load whole to reason about structure, duplication, and refactors.
//
// Usage: node map.ts <repoRoot> [--out file] [--mode dense|skeleton|exports|sigs|full]
//                    [--include a,b,c] [--boundary x,y] [--include-tests] [--no-docs] [--fn-consts-only]
//                    [--members] [--public-only]
//
// TS: parse-only (no type-checking) via the `typescript` package resolved from the target repo
// or this skill dir; ~15k files in <10s. Swift: zero-dependency regex/brace-depth scanner.
// Runs on Node >= 23.6 (type stripping); older Node: `npx tsx map.ts ...`.

import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

type Mode = 'dense' | 'skeleton' | 'exports' | 'sigs' | 'full';

interface Options {
  repoRoot: string;
  out: string;
  mode: Mode;
  include: string[];
  boundary: string[];
  includeTests: boolean;
  noDocs: boolean;
  fnConstsOnly: boolean;
  reCounts: boolean;
  maxPerKind: number;
  members: boolean;
  publicOnly: boolean;
}

function parseArgs(argv: string[]): Options {
  const [repoArg, ...rest] = argv;
  if (!repoArg || repoArg.startsWith('--')) {
    console.error('usage: node map.ts <repoRoot> [--out file] [--mode dense|skeleton|exports|sigs|full] [--include a,b] [--boundary x,y] [--include-tests] [--no-docs] [--fn-consts-only] [--members] [--public-only]  (--members/--public-only are Swift-only; ignored for TS files)');
    process.exit(2);
  }
  const opts: Options = {
    repoRoot: resolve(repoArg),
    out: 'project-structure-map.txt',
    mode: 'dense',
    include: [],
    boundary: [],
    includeTests: false,
    noDocs: false,
    fnConstsOnly: false,
    reCounts: false,
    maxPerKind: 0,
    members: false,
    publicOnly: false,
  };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--out') opts.out = rest[++i];
    else if (a === '--mode') opts.mode = rest[++i] as Mode;
    else if (a === '--include') opts.include = rest[++i].split(',').filter(Boolean);
    else if (a === '--boundary') opts.boundary = rest[++i].split(',').filter(Boolean);
    else if (a === '--include-tests') opts.includeTests = true;
    else if (a === '--no-docs') opts.noDocs = true;
    else if (a === '--fn-consts-only') opts.fnConstsOnly = true;
    else if (a === '--re-counts') opts.reCounts = true;
    else if (a === '--max-per-kind') opts.maxPerKind = Number(rest[++i]) || 0;
    else if (a === '--members') opts.members = true;
    else if (a === '--public-only') opts.publicOnly = true;
    else {
      console.error(`unknown option: ${a}`);
      process.exit(2);
    }
  }
  if (!['dense', 'skeleton', 'exports', 'sigs', 'full'].includes(opts.mode)) {
    console.error(`invalid --mode: ${opts.mode}`);
    process.exit(2);
  }
  return opts;
}

function loadTypescript(repoRoot: string): any {
  for (const from of [join(repoRoot, 'package.json'), import.meta.url]) {
    try {
      return createRequire(from)('typescript');
    } catch {
      /* try next */
    }
  }
  console.error('Cannot resolve the `typescript` package from the target repo or the skill directory.');
  console.error('Fix: run `npm i typescript` in either location.');
  process.exit(2);
}

const opts = parseArgs(process.argv.slice(2));
// Lazy: a pure-Swift repo must not require the `typescript` package at all.
let ts: any = null;

const SKIP_DIRS = new Set(['node_modules', 'dist', 'out', '.git', 'coverage', 'build', '.next', 'fixtures', '__fixtures__', 'vendor']);
const TEST_INFRA_DIRS = ['test-support', 'test-helpers', 'e2e', 'test', 'tests', '__tests__', 'testing'];
if (!opts.includeTests) for (const d of TEST_INFRA_DIRS) SKIP_DIRS.add(d);

const MAX_SIG = 400;
const MAX_TYPE_BODY = 600;
const MAX_DOC = 140;

const isTestFile = (name: string): boolean =>
  !opts.includeTests && (/\.(test|spec|e2e\.test)\.tsx?$/.test(name) || /(test-support|test-helpers|test-utils)/.test(name));

// Swift test convention is path-based (SwiftPM `Tests/` targets, `*Tests.swift` naming),
// unlike the TS infix suffixes above. Match repo-relative paths only — an ancestor dir named
// `Tests` outside the repo must not exclude the whole checkout.
const isSwiftTestFile = (path: string): boolean => {
  if (opts.includeTests) return false;
  const rel = relative(opts.repoRoot, path);
  return /(^|\/)Tests?\//.test(rel) || /Tests\.swift$/.test(rel);
};

function isSourceFile(name: string, path: string): boolean {
  if (/\.(ts|tsx)$/.test(name)) return !/\.d\.ts$/.test(name) && !isTestFile(name);
  if (name.endsWith('.swift')) return !isSwiftTestFile(path);
  return false;
}

function* walk(dir: string): Generator<string> {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      yield* walk(p);
    } else if (isSourceFile(e.name, p)) {
      yield p;
    }
  }
}

const squash = (s: string): string => s.replace(/\s+/g, ' ').trim();
const cap = (s: string, n: number): string => (s.length > n ? s.slice(0, n) + '…' : s);

function docFirstLine(node: any, sf: any): string {
  if (opts.noDocs) return '';
  const ranges = ts.getLeadingCommentRanges(sf.text, node.getFullStart());
  if (!ranges?.length) return '';
  const r = ranges[ranges.length - 1];
  const text = sf.text
    .slice(r.pos, r.end)
    .replace(/^\/\*\*?/, '')
    .replace(/\*\/$/, '')
    .replace(/^\s*\*\s?/gm, '')
    .replace(/^\/\/\s?/gm, '');
  const line = text
    .split('\n')
    .map((l: string) => l.trim())
    .find((l: string) => l && !l.startsWith('@'));
  return line ? cap(line, MAX_DOC) : '';
}

function sigText(node: any, sf: any): string {
  const end = node.body ? node.body.getStart(sf) : node.getEnd();
  return cap(squash(sf.text.slice(node.getStart(sf), end)), MAX_SIG);
}

const isExported = (node: any): boolean =>
  node.modifiers?.some((m: any) => m.kind === ts.SyntaxKind.ExportKeyword) ?? false;

const isFnValued = (d: any): boolean =>
  d.initializer && (ts.isArrowFunction(d.initializer) || ts.isFunctionExpression(d.initializer));

// Destructured declarations (`const { a: b, c } = …`) must emit each BOUND name on its own,
// never `d.name.getText()` — that leaks a raw multi-line `{ … }` literal into the map.
function boundNames(name: any): string[] {
  if (ts.isIdentifier(name)) return [name.text];
  const names: string[] = [];
  if (ts.isObjectBindingPattern(name) || ts.isArrayBindingPattern(name)) {
    for (const el of name.elements) {
      if (ts.isBindingElement(el)) names.push(...boundNames(el.name));
    }
  }
  return names;
}

function classShape(node: any, sf: any): string {
  const name = node.name?.text ?? '(anon)';
  const heritage = node.heritageClauses?.map((h: any) => squash(h.getText(sf))).join(' ') ?? '';
  const members: string[] = [];
  for (const m of node.members) {
    const mods = m.modifiers?.map((x: any) => x.getText(sf)) ?? [];
    if (mods.includes('private')) continue;
    if (ts.isConstructorDeclaration(m)) {
      members.push(squash('constructor' + sf.text.slice(m.parameters.pos - 1, m.body ? m.body.getStart(sf) : m.getEnd())));
    } else if (ts.isMethodDeclaration(m) || ts.isGetAccessorDeclaration(m) || ts.isSetAccessorDeclaration(m)) {
      members.push(sigText(m, sf));
    } else if (ts.isPropertyDeclaration(m) && m.type) {
      members.push(squash(m.name.getText(sf) + ': ' + m.type.getText(sf)));
    }
  }
  return `class ${name}${heritage ? ' ' + heritage : ''} { ${cap(members.join('; '), MAX_TYPE_BODY)} }`;
}

// dense: [kind, name] tuples grouped per file; other modes: rendered lines
type DenseEntry = [string, string];
const denseDirs = new Map<string, string[]>();
const out: string[] = [];
let symbolTotal = 0;

function emitDense(file: string, entries: DenseEntry[]): void {
  const rel = relative(opts.repoRoot, file);
  const slash = rel.lastIndexOf('/');
  const dir = slash < 0 ? './' : rel.slice(0, slash + 1);
  const base = (slash < 0 ? rel : rel.slice(slash + 1)).replace(/\.(tsx?|swift)$/, '');
  const byKind = new Map<string, string[]>();
  for (const [k, n] of entries) {
    if (!byKind.has(k)) byKind.set(k, []);
    byKind.get(k)!.push(n);
  }
  // --re-counts: barrel targets collapse to a count; facade detail costs more than it informs at recon tier
  if (opts.reCounts && byKind.has('re')) byKind.set('re', [String(byKind.get('re')!.length)]);
  const capList = (ns: string[]): string =>
    opts.maxPerKind && ns.length > opts.maxPerKind
      ? ns.slice(0, opts.maxPerKind).join(',') + `+${ns.length - opts.maxPerKind}`
      : ns.join(',');
  const parts = [...byKind.entries()].map(([k, ns]) => `${k}:${capList(ns)}`);
  if (!denseDirs.has(dir)) denseDirs.set(dir, []);
  denseDirs.get(dir)!.push(`${base} ${parts.join(' ')}`);
}

function emitFile(file: string, sf: any): boolean {
  const lines: string[] = [];
  const dense: DenseEntry[] = [];
  const importCount = sf.statements.filter((s: any) => ts.isImportDeclaration(s)).length;

  for (const st of sf.statements) {
    const exp = isExported(st);
    if (opts.mode !== 'full' && !exp && !ts.isExportDeclaration(st)) continue;
    const tag = exp ? '' : 'internal ';
    const doc = docFirstLine(st, sf);
    const suffix = doc && opts.mode !== 'skeleton' ? `  // ${doc}` : '';

    if (opts.mode === 'dense') {
      if (ts.isFunctionDeclaration(st) && st.name) dense.push(['fn', st.name.text]);
      else if (ts.isClassDeclaration(st) && st.name) dense.push(['cl', st.name.text]);
      else if (ts.isInterfaceDeclaration(st) || ts.isTypeAliasDeclaration(st) || ts.isEnumDeclaration(st)) dense.push(['ty', st.name.text]);
      else if (ts.isVariableStatement(st)) {
        for (const d of st.declarationList.declarations) {
          if (!ts.isIdentifier(d.name)) {
            // fn-ness of a destructured value is unknowable without type info; always kind `c`.
            if (!opts.fnConstsOnly) for (const n of boundNames(d.name)) dense.push(['c', n]);
            continue;
          }
          if (opts.fnConstsOnly && !isFnValued(d)) continue;
          dense.push([isFnValued(d) ? 'fn' : 'c', d.name.text]);
        }
      } else if (ts.isExportDeclaration(st) && st.moduleSpecifier) {
        dense.push(['re', squash(st.moduleSpecifier.getText(sf)).replace(/["']/g, '')]);
      }
      continue;
    }

    if (opts.mode === 'skeleton') {
      if (ts.isFunctionDeclaration(st) && st.name) lines.push(`fn ${st.name.text}`);
      else if (ts.isClassDeclaration(st) && st.name) lines.push(`class ${st.name.text}`);
      else if (ts.isInterfaceDeclaration(st)) lines.push(`interface ${st.name.text}`);
      else if (ts.isTypeAliasDeclaration(st)) lines.push(`type ${st.name.text}`);
      else if (ts.isEnumDeclaration(st)) lines.push(`enum ${st.name.text}`);
      else if (ts.isVariableStatement(st)) for (const d of st.declarationList.declarations) for (const n of boundNames(d.name)) lines.push(`const ${n}`);
      else if (ts.isExportDeclaration(st)) lines.push(cap(squash(st.getText(sf)), 120));
      continue;
    }

    if (ts.isFunctionDeclaration(st) && st.name) {
      lines.push(`${tag}${sigText(st, sf)}${suffix}`);
    } else if (ts.isClassDeclaration(st)) {
      lines.push(`${tag}${classShape(st, sf)}${suffix}`);
    } else if (ts.isInterfaceDeclaration(st)) {
      if (opts.mode === 'sigs') {
        lines.push(`${tag}interface ${st.name.text} { ${st.members.map((m: any) => m.name?.getText(sf) ?? '?').join(', ')} }${suffix}`);
      } else {
        lines.push(`${tag}${cap(squash(st.getText(sf)), MAX_TYPE_BODY)}${suffix}`);
      }
    } else if (ts.isTypeAliasDeclaration(st)) {
      if (opts.mode === 'sigs' && ts.isTypeLiteralNode(st.type)) {
        lines.push(`${tag}type ${st.name.text} { ${st.type.members.map((m: any) => m.name?.getText(sf) ?? '?').join(', ')} }${suffix}`);
      } else if (opts.mode === 'sigs') {
        lines.push(`${tag}type ${st.name.text} = ${cap(squash(st.type.getText(sf)), 200)}${suffix}`);
      } else {
        lines.push(`${tag}${cap(squash(st.getText(sf)), MAX_TYPE_BODY)}${suffix}`);
      }
    } else if (ts.isEnumDeclaration(st)) {
      lines.push(`${tag}enum ${st.name.text} { ${st.members.map((m: any) => m.name.getText(sf)).join(', ')} }${suffix}`);
    } else if (ts.isVariableStatement(st)) {
      for (const d of st.declarationList.declarations) {
        if (!ts.isIdentifier(d.name)) {
          // Typed modes keep the pattern with its annotation (squashed to one line — the raw
          // getText leaks multi-line literals); per-element names are the dense/skeleton shape.
          if (opts.fnConstsOnly) continue;
          let patternAnn = '';
          if (d.type) patternAnn = ': ' + squash(d.type.getText(sf));
          else if (d.initializer) patternAnn = ` = <${ts.SyntaxKind[d.initializer.kind]}>`;
          patternAnn = cap(patternAnn, MAX_SIG);
          if (exp || patternAnn.startsWith(': ')) {
            lines.push(`${tag}const ${cap(squash(d.name.getText(sf)), MAX_SIG)}${patternAnn}${suffix}`);
          }
          continue;
        }
        if (opts.fnConstsOnly && !isFnValued(d)) continue;
        const name = d.name.text;
        let ann = '';
        if (d.type) ann = ': ' + squash(d.type.getText(sf));
        else if (d.initializer) {
          if (isFnValued(d)) {
            const fn = d.initializer;
            ann = ' = ' + squash(sf.text.slice(fn.getStart(sf), fn.body ? fn.body.getStart(sf) : fn.getEnd())) + '…';
          } else {
            ann = ` = <${ts.SyntaxKind[d.initializer.kind]}>`;
          }
        }
        ann = cap(ann, MAX_SIG);
        if (exp || ann.includes('=>') || ann.startsWith(': ')) {
          lines.push(`${tag}const ${name}${ann}${suffix}`);
        }
      }
    } else if (ts.isExportDeclaration(st)) {
      lines.push(squash(st.getText(sf)));
    }
  }

  if (opts.mode === 'dense') {
    if (dense.length === 0) return false;
    emitDense(file, dense);
    symbolTotal += dense.length;
    return true;
  }
  if (lines.length === 0) return false;
  out.push(`## ${relative(opts.repoRoot, file)}  [imports:${importCount}]`);
  out.push(...lines, '');
  symbolTotal += lines.length;
  return true;
}

// --- Swift scanner (zero-dependency regex/brace-depth line scanner; validated 1:1 against
// SourceKitten top-level output on 1,850 files across two real repos) ---

interface SwiftSymbol {
  kind: string;
  name: string;
  access: string;
  memberOf: string;
}

// Blank out comments (line + nested block) and string literals (regular, raw #"…"#,
// multiline """) so the declaration regex and brace counter never see keyword-lookalikes
// inside them. Preserves newlines and byte offsets per line.
function maskSwiftNonCode(source: string): string {
  let out = '';
  let state = 'code';
  let blockDepth = 0;
  let rawHashes = 0;
  let interpDepth = 0;
  let interpReturn = 'string';
  let interpInString = false;
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    const next = source[i + 1];
    if (state === 'lineComment') {
      if (ch === '\n') { state = 'code'; out += '\n'; } else out += ' ';
    } else if (state === 'blockComment') {
      if (ch === '/' && next === '*') { blockDepth++; out += '  '; i++; }
      else if (ch === '*' && next === '/') { blockDepth--; out += '  '; i++; if (blockDepth === 0) state = 'code'; }
      else out += ch === '\n' ? '\n' : ' ';
    } else if (state === 'interp') {
      // \( … ) interpolation: mask until parens balance so a nested string literal's quote
      // is never taken for the outer string's closer. Single-line nested literals are skipped
      // so their parens/quotes don't move the depth; raw/multiline literals nested inside an
      // interpolation stay best-effort — accepted limitation of the parserless design.
      if (interpInString) {
        if (ch === '\\' && i + 1 < source.length) { out += source[i + 1] === '\n' ? ' \n' : '  '; i++; }
        else { if (ch === '"') interpInString = false; out += ch === '\n' ? '\n' : ' '; }
      } else if (ch === '"') {
        interpInString = true; out += ' ';
      } else {
        if (ch === '(') interpDepth++;
        else if (ch === ')' && --interpDepth === 0) state = interpReturn;
        out += ch === '\n' ? '\n' : ' ';
      }
    } else if (state === 'string' || state === 'multiline') {
      // Escapes apply in multiline strings too (e.g. \""" must not close the literal);
      // raw strings (rawHashes > 0) escape via \#…# instead, so plain \ passes through
      // but \#…#" must not read as delimiter (`\#"#` would otherwise close a #"…"# early).
      const closer = (state === 'multiline' ? '"""' : '"') + '#'.repeat(rawHashes);
      const rawEscape = rawHashes > 0 && ch === '\\' && source.startsWith('#'.repeat(rawHashes), i + 1);
      if (rawHashes === 0 && ch === '\\' && next === '(') {
        out += '  '; i++; interpDepth = 1; interpInString = false; interpReturn = state; state = 'interp';
      } else if (rawHashes === 0 && ch === '\\') {
        out += ' '; if (i + 1 < source.length) { out += source[i + 1] === '\n' ? '\n' : ' '; i++; }
      } else if (rawEscape) {
        // \#…#( opens raw-string interpolation — same balanced-paren masking as \( above.
        const escapedChar = source[i + 1 + rawHashes];
        const width = Math.min(1 + rawHashes + 1, source.length - i);
        for (let k = 0; k < width; k++) out += source[i + k] === '\n' ? '\n' : ' ';
        i += width - 1;
        if (escapedChar === '(') { interpDepth = 1; interpInString = false; interpReturn = state; state = 'interp'; }
      } else if (source.startsWith(closer, i)) {
        out += ' '.repeat(closer.length); i += closer.length - 1; state = 'code';
      } else out += ch === '\n' ? '\n' : ' ';
    } else if (state === 'extRegex') {
      const closer = '/' + '#'.repeat(rawHashes);
      if (source.startsWith(closer, i)) {
        out += ' '.repeat(closer.length); i += closer.length - 1; state = 'code';
      } else out += ch === '\n' ? '\n' : ' ';
    } else if (ch === '/' && next === '/') {
      state = 'lineComment'; out += '  '; i++;
    } else if (ch === '/' && next === '*') {
      state = 'blockComment'; blockDepth = 1; out += '  '; i++;
    } else {
      let hashes = 0;
      while (source[i + hashes] === '#') hashes++;
      if (source[i + hashes] === '"') {
        rawHashes = hashes;
        const triple = source.startsWith('"""', i + hashes);
        const width = hashes + (triple ? 3 : 1);
        out += ' '.repeat(width); i += width - 1; state = triple ? 'multiline' : 'string';
      } else if (hashes > 0 && source[i + hashes] === '/') {
        // Extended-delimiter regex literal #/…/# (incl. multiline). Bare /…/ regex literals
        // are lexically ambiguous with division without a parser and stay unmasked — a brace
        // inside one can desync the depth counter; accepted limitation.
        rawHashes = hashes;
        out += ' '.repeat(hashes + 1); i += hashes; state = 'extRegex';
      } else out += ch;
    }
  }
  return out;
}

// Leading attributes are removed by a linear scan. Keeping them in SWIFT_DECL makes
// `  @.` repeat until the matcher backtracks for seconds and never finds a declaration.
function stripSwiftLeadingAttributes(line: string): string {
  let i = 0;
  const len = line.length;
  while (i < len) {
    let j = i;
    while (j < len && (line[j] === ' ' || line[j] === '\t')) j++;
    if (line[j] !== '@') return line.slice(i);
    j++;
    if (j >= len || !/[\w.]/.test(line[j])) return line.slice(i);
    while (j < len && /[\w.]/.test(line[j])) j++;
    if (line[j] === '<') {
      const close = line.indexOf('>', j + 1);
      if (close < 0) return line.slice(i);
      j = close + 1;
    }
    if (line[j] === '(') {
      let depth = 0;
      let k = j;
      for (; k < len; k++) {
        if (line[k] === '(') depth++;
        else if (line[k] === ')') {
          depth--;
          if (depth === 0) {
            k++;
            break;
          }
        }
      }
      if (depth !== 0) return line.slice(i);
      j = k;
    }
    if (j < len && line[j] !== ' ' && line[j] !== '\t') return line.slice(i);
    i = j;
  }
  return line.slice(i);
}

const SWIFT_DECL = /^(\s*(?:(?:open|public|package|internal|private|fileprivate|(?:public|package|internal|private|fileprivate)\(set\)|final|indirect|nonisolated(?:\([^)]*\))?|static|class|override|required|convenience|mutating|nonmutating|prefix|postfix|infix|lazy|weak|unowned(?:\((?:safe|unsafe)\))?|dynamic|distributed|optional|borrowing|consuming)\s+)*)(func|class|struct|enum|protocol|extension|typealias|actor|macro|let|var)\b(.*)$/u;

const SWIFT_CONTAINER_WORDS = new Set(['class', 'struct', 'enum', 'protocol', 'extension', 'actor']);

// `private(set)`-style modifiers scope only the setter; strip them before reading access so
// `public private(set) var` and `private(set) var` resolve to the getter's access level.
const stripSetterAccess = (text: string): string =>
  text.replace(/\b(open|public|package|internal|private|fileprivate)\(set\)/g, '');

const swiftWrittenAccess = (text: string): string =>
  stripSetterAccess(text).match(/\b(open|public|package|internal|private|fileprivate)\b/)?.[1] ?? 'internal';

function swiftDeclKind(word: string): string {
  if (word === 'func') return 'fn';
  if (word === 'class' || word === 'actor') return 'cl';
  if (word === 'let' || word === 'var') return 'c';
  return 'ty';
}

function swiftDeclName(word: string, rest: string): string {
  if (word === 'extension') {
    // Target runs to a top-level `:`, `where`, or body `{`; whitespace inside bound generics
    // (`extension Result<Int, Error>`) is part of the target, not a terminator.
    let nesting = 0;
    let end = rest.length;
    for (let i = 0; i < rest.length; i++) {
      const ch = rest[i];
      if (ch === '<' || ch === '(' || ch === '[') nesting++;
      else if (ch === '>' || ch === ')' || ch === ']') nesting = Math.max(0, nesting - 1);
      else if (nesting === 0 && (ch === ':' || ch === '{')) { end = i; break; }
    }
    let target = rest.slice(0, end);
    const whereIndex = target.search(/\bwhere\b/);
    if (whereIndex >= 0) target = target.slice(0, whereIndex);
    target = target.replace(/\s+/g, '');
    return target ? `extension:${target}` : '';
  }
  if (word === 'func') {
    const match = rest.match(/^\s*(`[^`]+`|[\p{ID_Start}_$][\p{ID_Continue}$]*|[^\w\s(]+)\s*(?:<|\()/u);
    return match?.[1]?.replace(/^`|`$/g, '') ?? '';
  }
  return rest.match(/^\s*(`[^`]+`|[\p{ID_Start}_$][\p{ID_Continue}$]*)/u)?.[1]?.replace(/^`|`$/g, '') ?? '';
}

// Split on top-level commas only: commas inside (), [], {} belong to tuple types, argument
// lists, collection literals, or closures — splitting there truncates `let a = 1, b = 2`
// after `a` and invents names from tuple-type labels.
function splitTopLevelCommas(text: string): string[] {
  const segments: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '(' || ch === '[' || ch === '{') depth++;
    else if (ch === ')' || ch === ']' || ch === '}') depth = Math.max(0, depth - 1);
    else if (ch === ',' && depth === 0) { segments.push(text.slice(start, i)); start = i + 1; }
  }
  segments.push(text.slice(start));
  return segments;
}

const SWIFT_BINDING_NAME = /^\s*(`[^`]+`|[\p{ID_Start}_$][\p{ID_Continue}$]*)\s*(?=[:=\[{]|$)/u;

// Tuple patterns bind names inside parens: `let (left, (a, b)) = …`. Recurse per element;
// `_` is a wildcard, not a symbol. A pattern must be followed by `:`, `=`, or segment end —
// anything else (e.g. `>` from a generic-argument split like `Dictionary<String, (Int, Bool)>`)
// marks a type continuation, not a binding, and must not fabricate symbols.
function swiftTuplePatternNames(segment: string, topLevel = true): string[] {
  const open = segment.indexOf('(');
  let depth = 0;
  let close = -1;
  for (let i = open; i < segment.length; i++) {
    if (segment[i] === '(') depth++;
    else if (segment[i] === ')' && --depth === 0) { close = i; break; }
  }
  if (close < 0) return [];
  if (topLevel && !/^\s*(?:[:=]|$)/.test(segment.slice(close + 1))) return [];
  const names: string[] = [];
  for (const element of splitTopLevelCommas(segment.slice(open + 1, close))) {
    names.push(...swiftTupleElementNames(element));
  }
  return names;
}

// One tuple-pattern element: `label: pattern` binds via the pattern, not the label
// (`let (x: a, y: b) = value` declares a and b). Inside a tuple pattern `ident:` is
// always a label — the type-annotation reading exists only outside patterns.
function swiftTupleElementNames(element: string): string[] {
  const pattern = element.replace(/^\s*(?:`[^`]+`|[\p{ID_Start}_$][\p{ID_Continue}$]*)\s*:\s*/u, '');
  if (pattern.trimStart().startsWith('(')) return swiftTuplePatternNames(pattern, false);
  const match = pattern.match(SWIFT_BINDING_NAME);
  return match && match[1] !== '_' ? [match[1].replace(/^`|`$/g, '')] : [];
}

function swiftVariableNames(rest: string): string[] {
  // Segments reached while an earlier segment left `<…` open are generic-argument
  // continuations (`Triple<Int, (String, Bool), Double>`), not bindings — a tuple there
  // must not fabricate symbols. `>` from closure arrows clamps at zero harmlessly.
  const names: string[] = [];
  let angleBalance = 0;
  for (const segment of splitTopLevelCommas(rest)) {
    const insideGeneric = angleBalance > 0;
    let nest = 0;
    for (const ch of segment) {
      if (ch === '(' || ch === '[' || ch === '{') nest++;
      else if (ch === ')' || ch === ']' || ch === '}') nest = Math.max(0, nest - 1);
      else if (nest === 0 && ch === '<') angleBalance++;
      else if (nest === 0 && ch === '>') angleBalance = Math.max(0, angleBalance - 1);
    }
    if (insideGeneric) continue;
    if (segment.trimStart().startsWith('(')) {
      names.push(...swiftTuplePatternNames(segment));
      continue;
    }
    const match = segment.match(SWIFT_BINDING_NAME);
    if (match && match[1] !== '_') names.push(match[1].replace(/^`|`$/g, ''));
  }
  return names;
}

function scanSwiftSource(source: string): SwiftSymbol[] {
  const maskedLines = maskSwiftNonCode(source).split('\n');
  const found: SwiftSymbol[] = [];
  let depth = 0;
  let topContainer: { name: string; word: string; access: string } | null = null;
  let pendingContainer: typeof topContainer = null;
  // Only one #if branch exists in compiled source. Branches may open a shared body with
  // different headers (`#if … class V: A { #else class V: B { #endif … }`), so each #else
  // restores the branch-entry depth and #endif adopts the first branch's exit depth —
  // a no-op for balanced branches, and no linear double-count for split-container ones.
  const condStack: { startDepth: number; firstBranchDepth: number }[] = [];
  for (const maskedLine of maskedLines) {
    const directive = maskedLine.match(/^\s*#(if|elseif|else|endif)\b/);
    if (directive) {
      const kind = directive[1];
      if (kind === 'if') condStack.push({ startDepth: depth, firstBranchDepth: -1 });
      else if (condStack.length > 0) {
        const frame = condStack[condStack.length - 1];
        if (kind === 'endif') {
          condStack.pop();
          if (frame.firstBranchDepth >= 0) depth = frame.firstBranchDepth;
        } else {
          if (frame.firstBranchDepth < 0) frame.firstBranchDepth = depth;
          depth = frame.startDepth;
        }
      }
      continue;
    }
    const startDepth = depth;
    const match = stripSwiftLeadingAttributes(maskedLine).match(SWIFT_DECL);
    if (match) {
      // match[1] is the captured modifier run only — attributes stay outside it, so attribute
      // arguments like @_documentation(visibility: internal) cannot pollute access detection.
      const modifiers = match[1];
      const word = match[2];
      const rest = match[3];
      const topLevel = startDepth === 0;
      const member = opts.members && startDepth === 1 && topContainer;
      if (topLevel || (member && (word === 'func' || word === 'let' || word === 'var'))) {
        let access = swiftWrittenAccess(modifiers);
        // Members of a protocol/extension without a written modifier inherit the container's
        // access (Swift semantics); other containers default their members to internal.
        const explicitAccess = /\b(open|public|package|internal|private|fileprivate)\b/.test(stripSetterAccess(modifiers));
        if (member && !explicitAccess && (topContainer!.word === 'protocol' || topContainer!.word === 'extension')) {
          access = topContainer!.access;
        }
        const names = word === 'let' || word === 'var' ? swiftVariableNames(rest) : [swiftDeclName(word, rest)];
        for (const name of names.filter(Boolean)) {
          found.push({ kind: swiftDeclKind(word), name, access, memberOf: member ? topContainer!.name : '' });
        }
      }
      if (topLevel && SWIFT_CONTAINER_WORDS.has(word)) {
        // An unnamed container (identifier outside the matcher's range, e.g. emoji) must not
        // arm member attribution — bare member names would masquerade as top-level symbols.
        const containerName = swiftDeclName(word, rest).replace(/^extension:/, '');
        if (containerName) {
          pendingContainer = { name: containerName, word, access: swiftWrittenAccess(modifiers) };
        }
      }
    }
    // Promote the pending container only at braces after the declaration keyword — a closure
    // in an attribute argument (`@Macro(h: { _ in }) struct Box {`) opens/closes earlier on
    // the line and must not consume the container before its real body brace.
    const promoteFrom = match ? match[0].length - match[3].length : 0;
    for (let charIndex = 0; charIndex < maskedLine.length; charIndex++) {
      const ch = maskedLine[charIndex];
      if (ch === '{') {
        if (depth === 0 && pendingContainer && charIndex >= promoteFrom) {
          topContainer = pendingContainer; pendingContainer = null;
        }
        depth++;
      } else if (ch === '}') {
        depth = Math.max(0, depth - 1);
        if (depth === 0) topContainer = null;
      }
    }
  }
  return found;
}

function swiftSymbolLabel(s: SwiftSymbol): string {
  const qualified = s.memberOf ? `${s.memberOf}.${s.name}` : s.name;
  // internal is Swift's default; omitting its tag saves ~24% of Swift map bytes.
  return s.access === 'internal' ? qualified : `${qualified}[${s.access}]`;
}

const SWIFT_SKELETON_WORD: Record<string, string> = { fn: 'fn', cl: 'class', ty: 'type', c: 'const' };

function emitSwiftFile(file: string, source: string): boolean {
  let symbols = scanSwiftSource(source);
  // Swift closure-valued lets are indistinguishable from plain values without types, so
  // --fn-consts-only drops every let/var symbol.
  if (opts.fnConstsOnly) symbols = symbols.filter((s) => s.kind !== 'c');
  if (opts.publicOnly) symbols = symbols.filter((s) => s.access === 'public' || s.access === 'open');
  if (symbols.length === 0) return false;
  symbolTotal += symbols.length;
  if (opts.mode === 'dense') {
    emitDense(file, symbols.map((s): DenseEntry => [s.kind, swiftSymbolLabel(s)]));
    return true;
  }
  // Count on masked source so commented/string `import` lines don't count, and accept
  // attributed/access-scoped forms (@testable import, @_exported import, public import).
  const importCount = maskSwiftNonCode(source).match(/^[^\S\n]*(?:@[\w.]+(?:\([^)\n]*\))?[^\S\n]+)*(?:(?:open|public|package|internal|private|fileprivate)[^\S\n]+)?import\b/gm)?.length ?? 0;
  out.push(`## ${relative(opts.repoRoot, file)}  [imports:${importCount}]`);
  if (opts.mode === 'skeleton') {
    for (const s of symbols) out.push(`${SWIFT_SKELETON_WORD[s.kind]} ${swiftSymbolLabel(s)}`);
  } else {
    // Typed modes (exports/sigs/full) are TS-only: no fabricated Swift signatures.
    // Swift files fall back to their dense-style symbol line.
    const byKind = new Map<string, string[]>();
    for (const s of symbols) {
      if (!byKind.has(s.kind)) byKind.set(s.kind, []);
      byKind.get(s.kind)!.push(swiftSymbolLabel(s));
    }
    out.push([...byKind.entries()].map(([k, ns]) => `${k}:${ns.join(',')}`).join(' '));
  }
  out.push('');
  return true;
}

// --- main ---
const t0 = Date.now();
const boundarySet = new Set(opts.boundary);
let roots = opts.include;
if (roots.length === 0) {
  roots = readdirSync(opts.repoRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('.') && !SKIP_DIRS.has(e.name) && !boundarySet.has(e.name))
    .map((e) => e.name);
}
roots = roots.filter((r) => !boundarySet.has(r));

let files = 0;
let emitted = 0;

function processFile(file: string): void {
  files++;
  // Outside the skip-catch: loadTypescript exits the process with a clear message on total
  // resolution failure — a missing compiler must never degrade into a silently thin map.
  if (!file.endsWith('.swift') && !ts) ts = loadTypescript(opts.repoRoot);
  try {
    const text = readFileSync(file, 'utf8');
    if (file.endsWith('.swift')) {
      if (emitSwiftFile(file, text)) emitted++;
      return;
    }
    const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, /\.tsx$/.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
    if (emitFile(file, sf)) emitted++;
  } catch {
    /* unparseable file: skip */
  }
}

// --include absent: repoRoot's own top-level source files are part of the repo too (a repoRoot
// that IS a leaf source dir would otherwise map to nothing). With --include, roots are exact.
if (opts.include.length === 0) {
  for (const e of readdirSync(opts.repoRoot, { withFileTypes: true })) {
    if (!e.name.startsWith('.') && e.isFile() && isSourceFile(e.name, join(opts.repoRoot, e.name))) {
      processFile(join(opts.repoRoot, e.name));
    }
  }
}
for (const root of roots) {
  for (const file of walk(join(opts.repoRoot, root))) processFile(file);
}

if (opts.mode === 'dense') {
  for (const [dir, fileLines] of [...denseDirs.entries()].sort()) {
    out.push(`# ${dir}`, ...fileLines, '');
  }
}

// Boundary dirs: named children with one-line package descriptions, no symbol content.
for (const b of opts.boundary) {
  let children: string[];
  try {
    children = readdirSync(join(opts.repoRoot, b), { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name);
  } catch {
    continue;
  }
  out.push(`# boundary ${b}/ (${children.length} modules, contents omitted)`);
  for (const c of children) {
    let desc = '';
    try {
      desc = String(JSON.parse(readFileSync(join(opts.repoRoot, b, c, 'package.json'), 'utf8')).description ?? '');
    } catch {
      /* no package.json: name only */
    }
    out.push(desc ? `${c} — ${cap(desc, 120)}` : c);
  }
  out.push('');
}

const result = out.join('\n');
writeFileSync(opts.out, result);
console.log(
  JSON.stringify({
    mode: opts.mode,
    roots,
    boundary: opts.boundary,
    files,
    emitted,
    symbols: symbolTotal,
    bytes: result.length,
    approxTokens: Math.round(result.length / 4),
    out: opts.out,
    ms: Date.now() - t0,
  }),
);
