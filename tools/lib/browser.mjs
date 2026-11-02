// Zero-dependency headless Chrome driver (CDP over Node's built-in WebSocket) and vite server helper.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DEFAULT_PORT = 5188;

export class ToolError extends Error {}

export function findChrome() {
  const candidates = [
    process.env.CHROME_PATH, process.env.PUPPETEER_EXECUTABLE_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ];
  const bundled = path.join(os.homedir(), '.agent-browser/browsers');
  if (fs.existsSync(bundled)) {
    for (const dir of fs.readdirSync(bundled).sort().reverse()) {
      for (const rel of ['Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing', 'chrome', 'chrome-linux64/chrome']) candidates.push(path.join(bundled, dir, rel));
    }
  }
  const found = candidates.find(c => c && fs.existsSync(c));
  if (!found) throw new ToolError('No Chrome found. Install Google Chrome or set CHROME_PATH to a Chrome/Chromium binary.');
  return found;
}

const freePort = () => new Promise((resolve, reject) => {
  const server = net.createServer();
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => { const { port } = server.address(); server.close(() => resolve(port)); });
});

/** True when the dev server on :5188 serves this checkout (vite refuses /@fs paths outside its own repository with a 403). */
async function servesThisCheckout() {
  const base = `http://127.0.0.1:${DEFAULT_PORT}`;
  const posixRoot = repoRoot.split(path.sep).join('/').replace(/^\//, '');
  const ok = url => fetch(url).then(r => r.ok, () => false);
  return (await ok(`${base}/tools/export.html`)) && (await ok(`${base}/@fs/${posixRoot}/package.json`));
}

/** Reuse the dev server on :5188 only if it serves this checkout (unless EXPORT_OWN_SERVER is set), otherwise start vite on a free port; close() stops only what it started. */
export async function startServer() {
  if (!process.env.EXPORT_OWN_SERVER && await servesThisCheckout()) return { url: `http://127.0.0.1:${DEFAULT_PORT}`, close: async () => {}, reused: true };
  const { createServer } = await import('vite');
  const port = await freePort();
  const server = await createServer({
    configFile: path.join(repoRoot, 'apps/room-viewer/vite.config.ts'),
    server: { port, strictPort: true },
    logLevel: 'error',
  });
  await server.listen();
  return { url: `http://127.0.0.1:${port}`, close: () => server.close(), reused: false };
}

class Cdp {
  constructor(ws) {
    this.ws = ws; this.nextId = 1; this.pending = new Map(); this.listeners = [];
    ws.addEventListener('message', event => {
      const msg = JSON.parse(event.data);
      if (msg.id) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (p) msg.error ? p.reject(new ToolError(`CDP ${p.method}: ${msg.error.message}`)) : p.resolve(msg.result);
      } else for (const l of this.listeners) l(msg);
    });
  }
  send(method, params = {}, sessionId) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
  on(listener) { this.listeners.push(listener); }
}

/** Launch headless Chrome; returns { newPage(), close() }. Software 2D canvas keeps texture bytes stable across machines. */
export async function launchBrowser() {
  const chrome = findChrome();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'room-export-chrome-'));
  const args = [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
    '--disable-gpu', '--disable-accelerated-2d-canvas', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--hide-scrollbars', '--mute-audio', 'about:blank',
  ];
  const child = spawn(chrome, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', d => { stderr += d; });
  const close = async () => {
    child.kill('SIGKILL');
    await new Promise(r => (child.exitCode === null ? child.once('exit', r) : r()));
    fs.rmSync(profile, { recursive: true, force: true });
  };
  try {
    const portFile = path.join(profile, 'DevToolsActivePort');
    for (let i = 0; i < 200 && !fs.existsSync(portFile); i++) {
      if (child.exitCode !== null) throw new ToolError(`Chrome exited early:\n${stderr.slice(-800)}`);
      await new Promise(r => setTimeout(r, 50));
    }
    if (!fs.existsSync(portFile)) throw new ToolError(`Chrome did not open a debugging port:\n${stderr.slice(-800)}`);
    const [port, wsPath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
    const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
    await new Promise((resolve, reject) => { ws.addEventListener('open', resolve); ws.addEventListener('error', () => reject(new ToolError('cannot connect to Chrome DevTools'))); });
    const cdp = new Cdp(ws);
    return {
      chrome,
      async newPage({ width = 1200, height = 800 } = {}) {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        const send = (method, params) => cdp.send(method, params, sessionId);
        const page = { send, errors: [], bindings: new Map() };
        cdp.on(msg => {
          if (msg.sessionId !== sessionId) return;
          if (msg.method === 'Runtime.exceptionThrown') page.errors.push(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
          if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') page.errors.push(msg.params.args.map(a => a.value ?? a.description).join(' '));
          if (msg.method === 'Runtime.bindingCalled') page.bindings.get(msg.params.name)?.(msg.params.payload);
        });
        await send('Runtime.enable'); await send('Page.enable');
        await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
        page.binding = async (name, handler) => { page.bindings.set(name, handler); await send('Runtime.addBinding', { name }); };
        page.goto = async url => { await send('Page.navigate', { url }); };
        page.eval = async expression => {
          const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
          if (r.exceptionDetails) throw new ToolError(`page error: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
          return r.result.value;
        };
        page.waitFor = async (expression, timeoutMs) => {
          const end = Date.now() + timeoutMs;
          while (Date.now() < end) {
            if (await page.eval(`Boolean(${expression})`).catch(() => false)) return;
            await new Promise(r => setTimeout(r, 200));
          }
          throw new ToolError(`timed out after ${timeoutMs / 1000}s waiting for ${expression}`);
        };
        page.screenshot = async file => {
          const { data } = await send('Page.captureScreenshot', { format: 'png' });
          fs.writeFileSync(file, Buffer.from(data, 'base64'));
        };
        return page;
      },
      close,
    };
  } catch (error) {
    await close();
    throw error;
  }
}
