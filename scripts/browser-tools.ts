#!/usr/bin/env ts-node

/**
 * Minimal Chrome DevTools helpers inspired by Mario Zechner's
 * "What if you don't need MCP?" article.
 *
 * Keeps everything in one TypeScript CLI so agents (or humans) can drive Chrome
 * directly via the DevTools protocol without pulling in a large MCP server.
 */
import { Command } from 'commander';
import { execFileSync, execSync, spawn } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, realpathSync, rmSync, statSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { fileURLToPath } from 'node:url';
import { inspect } from 'node:util';
import puppeteer, { type HTTPRequest } from 'puppeteer-core';

/** Utility type so TypeScript knows the async function constructor */
type AsyncFunctionCtor = new (...args: string[]) => (...fnArgs: unknown[]) => Promise<unknown>;

const DEFAULT_PORT = 9222;
const DEFAULT_PROFILE_DIR = path.join(os.homedir(), '.cache', 'scraping');
const DEFAULT_CHROME_BIN = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function browserURL(port: number): string {
  return `http://localhost:${port}`;
}

async function connectBrowser(port: number) {
  return puppeteer.connect({ browserURL: browserURL(port), defaultViewport: null });
}

function resolveComparablePath(inputPath: string): string {
  let existingPath = path.resolve(inputPath);
  const missingSegments: string[] = [];
  while (!existsSync(existingPath)) {
    const parent = path.dirname(existingPath);
    if (parent === existingPath) break;
    missingSegments.unshift(path.basename(existingPath));
    existingPath = parent;
  }
  return path.join(realpathSync(existingPath), ...missingSegments);
}

function pathsOverlap(first: string, second: string): boolean {
  const relative = path.relative(first, second);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

export function copyChromeProfile(sourceDir: string, profileDir: string): void {
  const source = realpathSync(sourceDir);
  if (!statSync(source).isDirectory()) {
    throw new Error('Chrome profile source must be a directory');
  }

  let destinationLinkExists = false;
  try {
    destinationLinkExists = lstatSync(profileDir).isSymbolicLink();
  } catch {
    // Missing destinations are created below.
  }
  if (destinationLinkExists && !existsSync(profileDir)) {
    throw new Error('Chrome profile destination symlink target does not exist');
  }

  let destination = resolveComparablePath(profileDir);
  if (pathsOverlap(source, destination) || pathsOverlap(destination, source)) {
    throw new Error('Chrome profile source and destination must not overlap');
  }

  if (existsSync(profileDir) && statSync(profileDir).isDirectory()) {
    for (const entry of readdirSync(destination)) {
      rmSync(path.join(destination, entry), { recursive: true, force: true });
    }
  } else {
    rmSync(profileDir, { recursive: true, force: true });
    mkdirSync(profileDir, { recursive: true });
    destination = resolveComparablePath(profileDir);
  }
  cpSync(source, destination, {
    recursive: true,
    force: true,
    verbatimSymlinks: true,
  });
}

async function getActivePage(port: number) {
  const browser = await connectBrowser(port);
  const pages = await browser.pages();
  const page = pages.at(-1);
  if (!page) {
    await browser.disconnect();
    throw new Error('No active tab found');
  }
  return { browser, page };
}

const program = new Command();
program
  .name('browser-tools')
  .description('Lightweight Chrome DevTools helpers (no MCP required).')
  .configureHelp({ sortSubcommands: true })
  .showSuggestionAfterError();

program
  .command('start')
  .description('Launch Chrome with remote debugging enabled.')
  .option('-p, --port <number>', 'Remote debugging port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--profile', 'Copy your default Chrome profile before launch.', false)
  .option('--profile-dir <path>', 'Directory for the temporary Chrome profile.', DEFAULT_PROFILE_DIR)
  .option('--chrome-path <path>', 'Path to the Chrome binary.', DEFAULT_CHROME_BIN)
  .option('--kill-existing', 'Stop any running Google Chrome before launch (default: false).', false)
  .action(async (options) => {
    const { port, profile, profileDir, chromePath, killExisting } = options as {
      port: number;
      profile: boolean;
      profileDir: string;
      chromePath: string;
      killExisting: boolean;
    };

    if (killExisting) {
      try {
        execFileSync('killall', ['Google Chrome'], { stdio: 'ignore' });
      } catch {
        // ignore missing processes
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    mkdirSync(profileDir, { recursive: true });
    if (profile) {
      const source = path.join(os.homedir(), 'Library', 'Application Support', 'Google', 'Chrome');
      copyChromeProfile(source, profileDir);
    }

    spawn(chromePath, [`--remote-debugging-port=${port}`, `--user-data-dir=${profileDir}`, '--no-first-run', '--disable-popup-blocking'], {
      detached: true,
      stdio: 'ignore',
    }).unref();

    let connected = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        const browser = await connectBrowser(port);
        await browser.disconnect();
        connected = true;
        break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    }

    if (!connected) {
      console.error(`✗ Failed to start Chrome on port ${port}`);
      process.exit(1);
    }
    console.log(`✓ Chrome listening on http://localhost:${port}${profile ? ' (profile copied)' : ''}`);
  });

program
  .command('nav <url>')
  .description('Navigate the current tab or open a new tab.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--new', 'Open in a new tab.', false)
  .action(async (url: string, options) => {
    const port = options.port as number;
    const browser = await connectBrowser(port);
    try {
      if (options.new) {
        const page = await browser.newPage();
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        console.log('✓ Opened in new tab:', url);
      } else {
        const pages = await browser.pages();
        const page = pages.at(-1);
        if (!page) {
          throw new Error('No active tab found');
        }
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        console.log('✓ Navigated current tab to:', url);
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('eval <code...>')
  .description('Evaluate JavaScript in the active page context.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--pretty-print', 'Format array/object results with indentation.', false)
  .action(async (code: string[], options) => {
    const snippet = code.join(' ');
    const port = options.port as number;
    const pretty = Boolean(options.prettyPrint);
    const useColor = process.stdout.isTTY;

    const printPretty = (value: unknown) => {
      console.log(
        inspect(value, {
          depth: 6,
          colors: useColor,
          maxArrayLength: 50,
          breakLength: 80,
          compact: false,
        }),
      );
    };

    const { browser, page } = await getActivePage(port);
    try {
      const result = await page.evaluate((body) => {
        const ASYNC_FN = Object.getPrototypeOf(async () => {}).constructor as AsyncFunctionCtor;
        return new ASYNC_FN(`return (${body})`)();
      }, snippet);

      if (pretty) {
        printPretty(result);
      } else if (Array.isArray(result)) {
        result.forEach((entry, index) => {
          if (index > 0) {
            console.log('');
          }
          Object.entries(entry).forEach(([key, value]) => {
            console.log(`${key}: ${value}`);
          });
        });
      } else if (typeof result === 'object' && result !== null) {
        Object.entries(result).forEach(([key, value]) => {
          console.log(`${key}: ${value}`);
        });
      } else {
        console.log(result);
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('screenshot')
  .description('Capture the current viewport and print the temp PNG path.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .action(async (options) => {
    const port = options.port as number;
    const { browser, page } = await getActivePage(port);
    const client = await page.target().createCDPSession();
    try {
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filePath = path.join(os.tmpdir(), `screenshot-${timestamp}.png`);
      const layoutMetrics = await client.send('Page.getLayoutMetrics').catch(() => undefined);
      const layoutViewport = layoutMetrics?.layoutViewport as
        | { clientWidth: number; clientHeight: number; pageX?: number; pageY?: number }
        | undefined;

      let cssWidth = layoutViewport?.clientWidth;
      let cssHeight = layoutViewport?.clientHeight;
      const pageX = layoutViewport?.pageX ?? 0;
      const pageY = layoutViewport?.pageY ?? 0;

      if (!cssWidth || !cssHeight) {
        const viewport = page.viewport();
        cssWidth = viewport?.width;
        cssHeight = viewport?.height;
      }

      if (!cssWidth || !cssHeight) {
        const fallback = await page.evaluate(() => ({
          width: window.innerWidth,
          height: window.innerHeight,
        }));
        cssWidth = fallback.width;
        cssHeight = fallback.height;
      }

      const maxDimension = 2000;
      const scale =
        cssWidth && cssHeight
          ? Math.max(
              0.01,
              Math.min(1, maxDimension / Math.max(cssWidth, cssHeight)),
            )
          : 1;

      if (!cssWidth || !cssHeight) {
        await page.screenshot({ path: filePath });
        console.log(filePath);
        return;
      }

      const screenshot = await client.send('Page.captureScreenshot', {
        format: 'png',
        fromSurface: true,
        captureBeyondViewport: false,
        clip: {
          x: pageX,
          y: pageY,
          width: cssWidth,
          height: cssHeight,
          scale,
        },
      });

      await writeFile(filePath, Buffer.from(screenshot.data, 'base64'));
      console.log(filePath);
    } finally {
      try {
        await client.detach();
      } catch {
        // ignore
      }
      await browser.disconnect();
    }
  });

program
  .command('pick <message...>')
  .description('Interactive DOM picker that prints metadata for clicked elements.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .action(async (messageParts: string[], options) => {
    const message = messageParts.join(' ');
    const port = options.port as number;
    const { browser, page } = await getActivePage(port);
    try {
      await page.evaluate(() => {
        const scope = globalThis as typeof globalThis & {
          pickOverlayInjected?: boolean;
          pick?: (prompt: string) => Promise<unknown>;
        };
        if (scope.pickOverlayInjected) {
          return;
        }
        scope.pickOverlayInjected = true;
        scope.pick = async (prompt: string) =>
          new Promise((resolve) => {
            const selections: unknown[] = [];
            const selectedElements = new Set<HTMLElement>();

            const overlay = document.createElement('div');
            overlay.style.cssText =
              'position:fixed;top:0;left:0;width:100%;height:100%;z-index:2147483647;pointer-events:none';

            const highlight = document.createElement('div');
            highlight.style.cssText =
              'position:absolute;border:2px solid #3b82f6;background:rgba(59,130,246,0.1);transition:all 0.05s ease';
            overlay.appendChild(highlight);

            const banner = document.createElement('div');
            banner.style.cssText =
              'position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#1f2937;color:#fff;padding:12px 24px;border-radius:8px;font:14px system-ui;box-shadow:0 4px 12px rgba(0,0,0,0.3);pointer-events:auto;z-index:2147483647';

            const updateBanner = () => {
              banner.textContent = `${prompt} (${selections.length} selected, Cmd/Ctrl+click to add, Enter to finish, ESC to cancel)`;
            };

            const cleanup = () => {
              document.removeEventListener('mousemove', onMove, true);
              document.removeEventListener('click', onClick, true);
              document.removeEventListener('keydown', onKey, true);
              overlay.remove();
              banner.remove();
              selectedElements.forEach((el) => {
                el.style.outline = '';
              });
            };

            const serialize = (el: HTMLElement) => {
              const parents: string[] = [];
              let current = el.parentElement;
              while (current && current !== document.body) {
                const id = current.id ? `#${current.id}` : '';
                const cls = current.className ? `.${current.className.trim().split(/\s+/).join('.')}` : '';
                parents.push(`${current.tagName.toLowerCase()}${id}${cls}`);
                current = current.parentElement;
              }
              return {
                tag: el.tagName.toLowerCase(),
                id: el.id || null,
                class: el.className || null,
                text: el.textContent?.trim()?.slice(0, 200) || null,
                html: el.outerHTML.slice(0, 500),
                parents: parents.join(' > '),
              };
            };

            const onMove = (event: MouseEvent) => {
              const node = document.elementFromPoint(event.clientX, event.clientY) as HTMLElement | null;
              if (!node || overlay.contains(node) || banner.contains(node)) return;
              const rect = node.getBoundingClientRect();
              highlight.style.cssText = `position:absolute;border:2px solid #3b82f6;background:rgba(59,130,246,0.1);top:${rect.top}px;left:${rect.left}px;width:${rect.width}px;height:${rect.height}px`;
            };
            const onClick = (event: MouseEvent) => {
              if (banner.contains(event.target as Node)) return;
              event.preventDefault();
              event.stopPropagation();
              const node = document.elementFromPoint(event.clientX, event.clientY) as HTMLElement | null;
              if (!node || overlay.contains(node) || banner.contains(node)) return;

              if (event.metaKey || event.ctrlKey) {
                if (!selectedElements.has(node)) {
                  selectedElements.add(node);
                  node.style.outline = '3px solid #10b981';
                  selections.push(serialize(node));
                  updateBanner();
                }
              } else {
                cleanup();
                const info = serialize(node);
                resolve(selections.length > 0 ? selections : info);
              }
            };

            const onKey = (event: KeyboardEvent) => {
              if (event.key === 'Escape') {
                cleanup();
                resolve(null);
              } else if (event.key === 'Enter' && selections.length > 0) {
                cleanup();
                resolve(selections);
              }
            };

            document.addEventListener('mousemove', onMove, true);
            document.addEventListener('click', onClick, true);
            document.addEventListener('keydown', onKey, true);

            document.body.append(overlay, banner);
            updateBanner();
          });
      });

      const result = await page.evaluate((msg) => {
        const pickFn = (window as Window & { pick?: (message: string) => Promise<unknown> }).pick;
        if (!pickFn) {
          return null;
        }
        return pickFn(msg);
      }, message);

      if (Array.isArray(result)) {
        result.forEach((entry, index) => {
          if (index > 0) {
            console.log('');
          }
          Object.entries(entry).forEach(([key, value]) => {
            console.log(`${key}: ${value}`);
          });
        });
      } else if (result && typeof result === 'object') {
        Object.entries(result).forEach(([key, value]) => {
          console.log(`${key}: ${value}`);
        });
      } else {
        console.log(result);
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('console')
  .description('Capture and display console logs from the active tab.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--types <list>', 'Comma-separated log types to show (e.g., log,error,warn). Default: all types')
  .option('--follow', 'Continuous monitoring mode (like tail -f)', false)
  .option('--timeout <seconds>', 'Capture duration in seconds (default: 5 for one-shot, infinite for --follow)', (value) => Number.parseInt(value, 10))
  .option('--color', 'Force color output')
  .option('--no-color', 'Disable color output')
  .option('--no-serialize', 'Disable object serialization (show raw text only)')
  .action(async (options) => {
    const port = options.port as number;
    const follow = options.follow as boolean;
    const timeout = options.timeout as number | undefined;
    const typesFilter = options.types as string | undefined;
    const serialize = options.serialize !== false;

    // Track explicit color flags by looking at argv to avoid Commander defaults overriding TTY detection.
    const argv = process.argv.slice(2);
    const colorFlag = argv.includes('--color') ? true : argv.includes('--no-color') ? false : undefined;

    // Determine if we should use colors: explicit flag or TTY auto-detection
    const useColor = colorFlag ?? process.stdout.isTTY;

    // Parse types filter
    const normalizeType = (value: string) => {
      const lower = value.toLowerCase();
      if (lower === 'warning') return 'warn';
      return lower;
    };

    const allowedTypes = typesFilter
      ? new Set(typesFilter.split(',').map((t) => normalizeType(t.trim())))
      : null; // null means show all types

    // Color functions (no-op if colors disabled)
    const colorize = (text: string, colorCode: string) => (useColor ? `\x1b[${colorCode}m${text}\x1b[0m` : text);
    const red = (text: string) => colorize(text, '31');
    const yellow = (text: string) => colorize(text, '33');
    const cyan = (text: string) => colorize(text, '36');
    const gray = (text: string) => colorize(text, '90');
    const white = (text: string) => text;

    const typeColors: Record<string, (text: string) => string> = {
      error: red,
      warn: yellow,
      warning: yellow,
      info: cyan,
      debug: gray,
      log: white,
      pageerror: red,
    };

    // Helper function definitions (outside try/catch as they don't need error handling)
    const formatTimestamp = () => {
      const now = new Date();
      return now.toTimeString().split(' ')[0] + '.' + now.getMilliseconds().toString().padStart(3, '0');
    };

    // Serialize value in Node.js util.inspect style with depth limit
    const formatValue = (value: any, depth = 0, maxDepth = 10): string => {
      if (depth > maxDepth) {
        return '[Object]';
      }

      if (value === null) return 'null';
      if (value === undefined) return 'undefined';
      if (typeof value === 'string') return `'${value}'`;
      if (typeof value === 'number' || typeof value === 'boolean') return String(value);
      if (typeof value === 'function') return '[Function]';

      if (Array.isArray(value)) {
        const items = value.map((v) => formatValue(v, depth + 1, maxDepth));
        return `[ ${items.join(', ')} ]`;
      }

      if (typeof value === 'object') {
        const entries = Object.entries(value).map(([k, v]) => `${k}: ${formatValue(v, depth + 1, maxDepth)}`);
        return entries.length > 0 ? `{ ${entries.join(', ')} }` : '{}';
      }

      return String(value);
    };

    // Serialize console message arguments
    const serializeArgs = async (msg: any): Promise<string> => {
      try {
        const args = msg.args();
        const values = await Promise.all(
          args.map(async (arg: any) => {
            try {
              const value = await arg.jsonValue();
              return formatValue(value);
            } catch (error) {
              const errorMsg = error instanceof Error ? error.message : String(error);
              if (errorMsg.includes('circular')) return '[Circular]';
              if (errorMsg.includes('reference chain')) return '[DeepObject]';
              return '[Unserializable]';
            }
          })
        );
        return values.join(' ');
      } catch {
        // Fallback to text representation
        return msg.text();
      }
    };

    const formatMessage = (type: string, text: string, location?: { url?: string; lineNumber?: number }) => {
      const color = typeColors[type] || white;
      const timestamp = formatTimestamp();
      const loc = location?.url && location?.lineNumber ? ` ${location.url}:${location.lineNumber}` : '';
      return color(`[${type.toUpperCase()}] ${timestamp} ${text}${loc}`);
    };

    // Execution code (needs try/catch for error handling)
    const { browser, page } = await getActivePage(port);

    try {
      // Set up console listener
      page.on('console', async (msg) => {
        const type = normalizeType(msg.type());
        if (allowedTypes && !allowedTypes.has(type)) {
          return; // Filter out unwanted types
        }

        const text = serialize ? await serializeArgs(msg) : msg.text();
        console.log(formatMessage(type, text, msg.location()));
      });

      // Set up page error listener
      page.on('pageerror', (error) => {
        if (allowedTypes && !allowedTypes.has('pageerror') && !allowedTypes.has('error')) {
          return;
        }
        console.log(formatMessage('pageerror', error.message));
      });

      if (follow) {
        // Continuous monitoring mode
        console.log(gray('Monitoring console logs (Ctrl+C to stop)...'));
        const waitForExit = () =>
          new Promise<void>((resolve) => {
            const signals: NodeJS.Signals[] = ['SIGINT', 'SIGTERM', 'SIGHUP'];
            const onSignal = () => {
              cleanup();
              resolve();
            };
            const onBeforeExit = () => {
              cleanup();
              resolve();
            };
            const cleanup = () => {
              signals.forEach((signal) => process.off(signal, onSignal));
              process.off('beforeExit', onBeforeExit);
            };
            signals.forEach((signal) => process.on(signal, onSignal));
            process.on('beforeExit', onBeforeExit);
          });

        await waitForExit();
      } else {
        // One-shot mode with timeout
        const duration = timeout ?? 5;
        console.log(gray(`Capturing console logs for ${duration} seconds...`));
        await new Promise((resolve) => setTimeout(resolve, duration * 1000));
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('network')
  .description('Capture network requests from the active tab from attach time; websocket shows only the upgrade handshake.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--types <list>', 'Comma-separated resource types (e.g., xhr,fetch,document). Default: all')
  .option('--follow', 'Continuous monitoring mode (like tail -f)', false)
  .option('--timeout <seconds>', 'Capture duration in seconds (default: 5 for one-shot, infinite for --follow)', (value) => Number.parseInt(value, 10))
  .option('--color', 'Force color output')
  .option('--no-color', 'Disable color output')
  .action(async (options) => {
    const port = options.port as number;
    const follow = options.follow as boolean;
    const timeout = options.timeout as number | undefined;
    const typesFilter = options.types as string | undefined;

    // Track explicit color flags by looking at argv to avoid Commander defaults overriding TTY detection.
    const argv = process.argv.slice(2);
    const colorFlag = argv.includes('--color') ? true : argv.includes('--no-color') ? false : undefined;

    // Determine if we should use colors: explicit flag or TTY auto-detection
    const useColor = colorFlag ?? process.stdout.isTTY;

    const allowedTypes = typesFilter
      ? new Set(typesFilter.split(',').map((t) => t.trim().toLowerCase()))
      : null; // null means show all types

    // Color functions (no-op if colors disabled)
    const colorize = (text: string, colorCode: string) => (useColor ? `\x1b[${colorCode}m${text}\x1b[0m` : text);
    const red = (text: string) => colorize(text, '31');
    const yellow = (text: string) => colorize(text, '33');
    const green = (text: string) => colorize(text, '32');
    const cyan = (text: string) => colorize(text, '36');
    const gray = (text: string) => colorize(text, '90');
    const white = (text: string) => text;

    const statusColor = (status: number) => {
      if (status >= 400) return red;
      if (status >= 300) return yellow;
      if (status >= 200) return green;
      return white;
    };

    const pad = (s: string, width: number) => (s.length >= width ? s : s + ' '.repeat(width - s.length));

    // Helper function definitions (outside try/catch as they don't need error handling)
    const formatTimestamp = () => {
      const now = new Date();
      return now.toTimeString().split(' ')[0] + '.' + now.getMilliseconds().toString().padStart(3, '0');
    };

    // Execution code (needs try/catch for error handling)
    const { browser, page } = await getActivePage(port);

    try {
      // Same HTTPRequest instance reaches response/failure; WeakMap avoids URL collisions.
      const requestStartedAt = new WeakMap<HTTPRequest, number>();

      page.on('request', (req) => {
        const resourceType = req.resourceType();
        if (allowedTypes && !allowedTypes.has(resourceType)) {
          return;
        }
        requestStartedAt.set(req, Date.now());
        console.log(`${cyan('[REQ ]')} ${gray(formatTimestamp())} ${pad(req.method(), 6)} ${pad(resourceType, 9)} ${req.url()}`);
      });

      page.on('response', (resp) => {
        const req = resp.request();
        const resourceType = req.resourceType();
        if (allowedTypes && !allowedTypes.has(resourceType)) {
          return;
        }
        const status = resp.status();
        const startedAt = requestStartedAt.get(req);
        const ms = startedAt !== undefined ? Date.now() - startedAt : undefined;
        const durationStr = ms !== undefined ? gray(` (${ms}ms)`) : '';
        console.log(`${statusColor(status)('[RESP]')} ${gray(formatTimestamp())} ${pad(String(status), 6)} ${pad(resourceType, 9)} ${req.url()}${durationStr}`);
      });

      page.on('requestfailed', (req) => {
        const resourceType = req.resourceType();
        if (allowedTypes && !allowedTypes.has(resourceType)) {
          return;
        }
        const failure = req.failure();
        const reason = failure ? failure.errorText : 'unknown';
        console.log(`${red('[FAIL]')} ${gray(formatTimestamp())} ${pad(req.method(), 6)} ${pad(resourceType, 9)} ${req.url()}  ${red('(' + reason + ')')}`);
      });

      if (follow) {
        // Continuous monitoring mode
        console.log(gray('Monitoring network requests (Ctrl+C to stop)...'));
        const waitForExit = () =>
          new Promise<void>((resolve) => {
            const signals: NodeJS.Signals[] = ['SIGINT', 'SIGTERM', 'SIGHUP'];
            const onSignal = () => {
              cleanup();
              resolve();
            };
            const onBeforeExit = () => {
              cleanup();
              resolve();
            };
            const cleanup = () => {
              signals.forEach((signal) => process.off(signal, onSignal));
              process.off('beforeExit', onBeforeExit);
            };
            signals.forEach((signal) => process.on(signal, onSignal));
            process.on('beforeExit', onBeforeExit);
          });

        await waitForExit();
      } else {
        // One-shot mode with timeout
        const duration = timeout ?? 5;
        console.log(gray(`Capturing network requests for ${duration} seconds...`));
        await new Promise((resolve) => setTimeout(resolve, duration * 1000));
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('search <query...>')
  .description('Google search with optional readable content extraction.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('-n, --count <number>', 'Number of results to return (default: 5, max: 50)', (value) => Number.parseInt(value, 10), 5)
  .option('--content', 'Fetch readable content for each result (slower).', false)
  .option('--timeout <seconds>', 'Per-navigation timeout in seconds (default: 10).', (value) => Number.parseInt(value, 10), 10)
  .action(async (queryWords: string[], options) => {
    const port = options.port as number;
    const count = Math.max(1, Math.min(options.count as number, 50));
    const fetchContent = Boolean(options.content);
    const timeoutMs = Math.max(3, (options.timeout as number) ?? 10) * 1000;
    const query = queryWords.join(' ');

    const { browser, page } = await getActivePage(port);
    try {
      const results: { title: string; link: string; snippet: string; content?: string }[] = [];
      let start = 0;
      while (results.length < count) {
        const searchUrl = `https://www.google.com/search?q=${encodeURIComponent(query)}&start=${start}`;
        await page.goto(searchUrl, { waitUntil: 'domcontentloaded', timeout: timeoutMs }).catch(() => {});
        await page.waitForSelector('div.MjjYud', { timeout: 3000 }).catch(() => {});

        const pageResults = await page.evaluate(() => {
          const items: { title: string; link: string; snippet: string }[] = [];
          document.querySelectorAll('div.MjjYud').forEach((result) => {
            const titleEl = result.querySelector('h3');
            const linkEl = result.querySelector('a');
            const snippetEl = result.querySelector('div.VwiC3b, div[data-sncf]');
            const link = linkEl?.getAttribute('href') ?? '';
            if (titleEl && linkEl && link && !link.startsWith('https://www.google.com')) {
              items.push({
                title: titleEl.textContent?.trim() ?? '',
                link,
                snippet: snippetEl?.textContent?.trim() ?? '',
              });
            }
          });
          return items;
        });

        for (const r of pageResults) {
          if (results.length >= count) break;
          if (!results.some((existing) => existing.link === r.link)) {
            results.push(r);
          }
        }

        if (pageResults.length === 0 || start >= 90) {
          break;
        }
        start += 10;
      }

      if (fetchContent) {
        for (const result of results) {
          try {
            await page.goto(result.link, { waitUntil: 'networkidle2', timeout: timeoutMs }).catch(() => {});
            const article = await extractReadableContent(page);
            result.content = article.content ?? '(No readable content)';
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            result.content = `(Error fetching content: ${message})`;
          }
        }
      }

      results.forEach((r, index) => {
        console.log(`--- Result ${index + 1} ---`);
        console.log(`Title: ${r.title}`);
        console.log(`Link: ${r.link}`);
        if (r.snippet) {
          console.log(`Snippet: ${r.snippet}`);
        }
        if (r.content) {
          console.log(`Content:\n${r.content}`);
        }
        console.log('');
      });

      if (results.length === 0) {
        console.log('No results found.');
      }
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('content <url>')
  .description('Extract readable content from a URL as markdown-like text.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .option('--timeout <seconds>', 'Navigation timeout in seconds (default: 10).', (value) => Number.parseInt(value, 10), 10)
  .action(async (url: string, options) => {
    const port = options.port as number;
    const timeoutMs = Math.max(3, (options.timeout as number) ?? 10) * 1000;
    const { browser, page } = await getActivePage(port);
    try {
      await page.goto(url, { waitUntil: 'networkidle2', timeout: timeoutMs }).catch(() => {});
      const article = await extractReadableContent(page);
      console.log(`URL: ${article.url}`);
      if (article.title) {
        console.log(`Title: ${article.title}`);
      }
      console.log('');
      console.log(article.content ?? '(No readable content)');
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('cookies')
  .description('Dump cookies from the active tab as JSON.')
  .option('--port <number>', 'Debugger port (default: 9222)', (value) => Number.parseInt(value, 10), DEFAULT_PORT)
  .action(async (options) => {
    const port = options.port as number;
    const { browser, page } = await getActivePage(port);
    try {
      const cookies = await page.cookies();
      console.log(JSON.stringify(cookies, null, 2));
    } finally {
      await browser.disconnect();
    }
  });

program
  .command('inspect')
  .description('List Chrome processes launched with --remote-debugging-port and show their open tabs.')
  .option('--ports <list>', 'Comma-separated list of ports to include.', parseNumberListArg)
  .option('--pids <list>', 'Comma-separated list of PIDs to include.', parseNumberListArg)
  .option('--json', 'Emit machine-readable JSON output.', false)
  .action(async (options) => {
    const ports = (options.ports as number[] | undefined)?.filter((entry) => Number.isFinite(entry) && entry > 0);
    const pids = (options.pids as number[] | undefined)?.filter((entry) => Number.isFinite(entry) && entry > 0);
    const sessions = await describeChromeSessions({
      ports,
      pids,
      includeAll: !ports?.length && !pids?.length,
    });
    if (options.json) {
      console.log(JSON.stringify(sessions, null, 2));
      return;
    }
    if (sessions.length === 0) {
      console.log('No Chrome instances with DevTools ports found.');
      return;
    }
    sessions.forEach((session, index) => {
      if (index > 0) {
        console.log('');
      }
      const transport = session.port !== undefined ? `port ${session.port}` : session.usesPipe ? 'debugging pipe' : 'unknown transport';
      const header = [`Chrome PID ${session.pid}`, `(${transport})`];
      if (session.version?.Browser) {
        header.push(`- ${session.version.Browser}`);
      }
      console.log(header.join(' '));
      if (session.tabs.length === 0) {
        console.log('  (no tabs reported)');
        return;
      }
      session.tabs.forEach((tab, idx) => {
        const title = tab.title || '(untitled)';
        const url = tab.url || '(no url)';
        console.log(`  Tab ${idx + 1}: ${title}`);
        console.log(`           ${url}`);
      });
    });
  });

program
  .command('kill')
  .description('Terminate Chrome instances that have DevTools ports open.')
  .option('--ports <list>', 'Comma-separated list of ports to target.', parseNumberListArg)
  .option('--pids <list>', 'Comma-separated list of PIDs to target.', parseNumberListArg)
  .option('--all', 'Kill every matching Chrome instance.', false)
  .option('--force', 'Skip the confirmation prompt.', false)
  .action(async (options) => {
    const ports = (options.ports as number[] | undefined)?.filter((entry) => Number.isFinite(entry) && entry > 0);
    const pids = (options.pids as number[] | undefined)?.filter((entry) => Number.isFinite(entry) && entry > 0);
    const killAll = Boolean(options.all);
    if (!killAll && (!ports?.length && !pids?.length)) {
      console.error('Specify --all, --ports <list>, or --pids <list> to select targets.');
      process.exit(1);
    }
    const sessions = await describeChromeSessions({ ports, pids, includeAll: killAll });
    if (sessions.length === 0) {
      console.log('No matching Chrome instances found.');
      return;
    }
    if (!options.force) {
      console.log('About to terminate the following Chrome sessions:');
      sessions.forEach((session) => {
        const transport = session.port !== undefined ? `port ${session.port}` : session.usesPipe ? 'debugging pipe' : 'unknown transport';
        console.log(`  PID ${session.pid} (${transport})`);
      });
      const rl = readline.createInterface({ input, output });
      const answer = (await rl.question('Proceed? [y/N] ')).trim().toLowerCase();
      rl.close();
      if (answer !== 'y' && answer !== 'yes') {
        console.log('Aborted.');
        return;
      }
    }
    const failures: { pid: number; error: string }[] = [];
    sessions.forEach((session) => {
      try {
        process.kill(session.pid);
        const transport = session.port !== undefined ? `port ${session.port}` : session.usesPipe ? 'debugging pipe' : 'unknown transport';
        console.log(`✓ Killed Chrome PID ${session.pid} (${transport})`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.error(`✗ Failed to kill PID ${session.pid}: ${message}`);
        failures.push({ pid: session.pid, error: message });
      }
    });
    if (failures.length > 0) {
      process.exitCode = 1;
    }
  });

interface ChromeProcessInfo {
  pid: number;
  port?: number;
  usesPipe: boolean;
  command: string;
}

interface ChromeTabInfo {
  id?: string;
  title?: string;
  url?: string;
  type?: string;
}

interface ChromeSessionDescription extends ChromeProcessInfo {
  version?: Record<string, string>;
  tabs: ChromeTabInfo[];
}

async function ensureReadability(page: any) {
  try {
    await page.setBypassCSP?.(true);
  } catch {
    // ignore
  }
  const scripts = [
    'https://unpkg.com/@mozilla/readability@0.6.0/Readability.js',
    'https://unpkg.com/turndown@7.2.4/dist/turndown.js',
    'https://unpkg.com/turndown-plugin-gfm@1.0.2/dist/turndown-plugin-gfm.js',
  ];
  for (const src of scripts) {
    try {
      const alreadyLoaded = await page.evaluate((url) => {
        return Boolean(document.querySelector(`script[src="${url}"]`));
      }, src);
      if (!alreadyLoaded) {
        await page.addScriptTag({ url: src });
      }
    } catch {
      // best-effort; continue
    }
  }
}

async function extractReadableContent(page: any): Promise<{ title?: string; content?: string; url: string }> {
  await ensureReadability(page);
  const result = await page.evaluate(() => {
    const asMarkdown = (html: string | null | undefined) => {
      if (!html) return '';
      const TurndownService = (window as any).TurndownService;
      const turndownPluginGfm = (window as any).turndownPluginGfm;
      if (!TurndownService) {
        return '';
      }
      const turndown = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced' });
      if (turndownPluginGfm?.gfm) {
        turndown.use(turndownPluginGfm.gfm);
      }
      return turndown
        .turndown(html)
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    };

    const fallbackText = () => {
      const main =
        document.querySelector('main, article, [role="main"], .content, #content') || document.body || document.documentElement;
      return main?.textContent?.trim() ?? '';
    };

    let title = document.title;
    let content = '';

    try {
      const Readability = (window as any).Readability;
      if (Readability) {
        const clone = document.cloneNode(true) as Document;
        const article = new Readability(clone).parse();
        title = article?.title || title;
        content = asMarkdown(article?.content) || article?.textContent || '';
      }
    } catch {
      // ignore readability failures
    }

    if (!content) {
      content = fallbackText();
    }

    content = content?.trim().slice(0, 8000);

    return { title, content, url: location.href };
  });
  return result;
}

function parseNumberListArg(value: string): number[] {
  return parseNumberList(value) ?? [];
}

function parseNumberList(inputValue: string | undefined): number[] | undefined {
  if (!inputValue) {
    return undefined;
  }
  const parsed = inputValue
    .split(',')
    .map((entry) => Number.parseInt(entry.trim(), 10))
    .filter((value) => Number.isFinite(value));
  return parsed.length > 0 ? parsed : undefined;
}

async function describeChromeSessions(options: {
  ports?: number[];
  pids?: number[];
  includeAll?: boolean;
}): Promise<ChromeSessionDescription[]> {
  const { ports, pids, includeAll } = options;
  const processes = await listDevtoolsChromes();
  const portSet = new Set(ports ?? []);
  const pidSet = new Set(pids ?? []);
  const candidates = processes.filter((proc) => {
    if (includeAll) {
      return true;
    }
    if (portSet.size > 0 && proc.port !== undefined && portSet.has(proc.port)) {
      return true;
    }
    if (pidSet.size > 0 && pidSet.has(proc.pid)) {
      return true;
    }
    return false;
  });
  const results: ChromeSessionDescription[] = [];
  for (const proc of candidates) {
    let version: Record<string, string> | undefined;
    let filteredTabs: ChromeTabInfo[] = [];
    if (proc.port !== undefined) {
      const [versionResp, tabs] = await Promise.all([
        fetchJson(`http://localhost:${proc.port}/json/version`).catch(() => undefined),
        fetchJson(`http://localhost:${proc.port}/json/list`).catch(() => []),
      ]);
      version = versionResp as Record<string, string> | undefined;
      filteredTabs = Array.isArray(tabs)
        ? (tabs as ChromeTabInfo[]).filter((tab) => {
            const type = tab.type?.toLowerCase() ?? '';
            if (type && type !== 'page' && type !== 'app') {
              if (!tab.url || tab.url.startsWith('devtools://') || tab.url.startsWith('chrome-extension://')) {
                return false;
              }
            }
            if (!tab.url || tab.url.trim().length === 0) {
              return false;
            }
            return true;
          })
        : [];
    }
    results.push({
      ...proc,
      version,
      tabs: filteredTabs,
    });
  }
  return results;
}

async function listDevtoolsChromes(): Promise<ChromeProcessInfo[]> {
  if (process.platform !== 'darwin' && process.platform !== 'linux') {
    console.warn('Chrome inspection is only supported on macOS and Linux for now.');
    return [];
  }
  let output = '';
  try {
    output = execSync('ps -ax -o pid=,command=', { encoding: 'utf8' });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to enumerate processes: ${message}`);
  }
  const processes: ChromeProcessInfo[] = [];
  output
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .forEach((line) => {
      const match = line.match(/^(\d+)\s+(.+)$/);
      if (!match) {
        return;
      }
      const pid = Number.parseInt(match[1], 10);
      const command = match[2];
      if (!Number.isFinite(pid) || pid <= 0) {
        return;
      }
      if (!/chrome/i.test(command) || (!/--remote-debugging-port/.test(command) && !/--remote-debugging-pipe/.test(command))) {
        return;
      }
      const portMatch = command.match(/--remote-debugging-port(?:=|\s+)(\d+)/);
      if (portMatch) {
        const port = Number.parseInt(portMatch[1], 10);
        if (!Number.isFinite(port)) {
          return;
        }
        processes.push({ pid, port, usesPipe: false, command });
        return;
      }
      if (/--remote-debugging-pipe/.test(command)) {
        processes.push({ pid, usesPipe: true, command });
      }
    });
  return processes;
}

function fetchJson(url: string, timeoutMs = 2000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { timeout: timeoutMs }, (response) => {
      const chunks: Buffer[] = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        if ((response.statusCode ?? 500) >= 400) {
          reject(new Error(`HTTP ${response.statusCode} for ${url}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch {
          resolve(undefined);
        }
      });
    });
    request.on('timeout', () => {
      request.destroy(new Error(`Request to ${url} timed out`));
    });
    request.on('error', (error) => {
      reject(error);
    });
  });
}

export function isMainModule(
  metaMain: boolean | null | undefined = import.meta.main,
  argvPath: string | undefined = process.argv[1],
  moduleUrl: string = import.meta.url,
): boolean {
  if (typeof metaMain === 'boolean') return metaMain;
  if (!argvPath) return false;

  const modulePath = fileURLToPath(moduleUrl);
  try {
    return realpathSync(argvPath) === realpathSync(modulePath);
  } catch {
    return path.resolve(argvPath) === modulePath;
  }
}

if (isMainModule()) {
  void program.parseAsync(process.argv);
}
