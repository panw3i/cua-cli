// cua: a plain command-line front end to the original Codex computer-use runtime, via an installed LCU.
// A background daemon keeps one connection to the runtime (its js state and app approvals live there);
// each `cua` command talks to it over a private Unix socket.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createConnection, createServer } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const VERSION = '0.1.0';
const LCU = process.env.LCU_HOME || join(homedir(), '.local/share/lcu/current');
const STATE = process.env.CUA_STATE_DIR || join(homedir(), '.local/state/cua-cli');
const SOCKET = join(STATE, 'daemon.sock');
const LOG = join(STATE, 'daemon.log');
const SHOTS = join(STATE, 'images');
const minutes = (name, fallback) => Number(process.env[name] ?? fallback) * 60_000;
const TURN_IDLE_MS = minutes('CUA_TURN_IDLE_MIN', 5);
const EXIT_IDLE_MS = minutes('CUA_EXIT_IDLE_MIN', 30);

const HELP = `cua ${VERSION} — computer use from the command line (original Codex runtime via LCU)

Usage:
  cua instructions            print the runtime's own instructions and js tool description (read first)
  cua js CODE                 run JavaScript in the computer-use REPL, e.g. cua js 'await cua.getState()'
  cua js -f FILE | cua js -   read the code from a file or stdin
      --timeout MS            pass timeout_ms to the runtime
      --json                  print the raw result instead of text + image paths
  cua reset                   reset the REPL (js_reset)
  cua end-turn                end the current turn (releases Computer Use; next call starts a new turn)
  cua apps [list|allow APP|revoke APP]   manage always-allowed apps (macOS, Touch ID)
  cua start | stop | status   control the background daemon (started automatically)
  cua doctor                  run LCU's readiness check

Environment:
  CUA_SESSION       session name; approvals "for this session" and REPL turns are per session (default: default)
  LCU_HOME          LCU installation (default: ~/.local/share/lcu/current)
  CUA_TURN_IDLE_MIN end a turn after this many idle minutes (default 5)
  CUA_EXIT_IDLE_MIN stop the daemon after this many idle minutes (default 30)

Images in results are written to ${SHOTS} and printed as [image: PATH].
Exit status: 0 ok, 1 the runtime reported an error, 2 usage or connection failure.
`;

// ---------- daemon ----------

async function daemon() {
  mkdirSync(STATE, { recursive: true, mode: 0o700 });
  const { createCuaClient, nativeAppApprovalOptions, nativeAppApprovalResponse } =
    await import(pathToFileURL(join(LCU, 'adapters/client.mjs')).href);

  const sessions = new Map(); // name -> { id, turn, timer }
  let lastActivity = Date.now();

  const cua = createCuaClient({
    command: [join(LCU, 'bin/lcu')],
    adapter: 'cua-cli',
    onElicitation: async (params, { signal } = {}) => {
      const request = nativeAppApprovalOptions(params);
      if (!request) return { action: 'cancel' }; // unknown request shape: fail closed
      const value = await askUser(params, request, signal);
      return nativeAppApprovalResponse(params, value);
    },
  });
  const ready = cua.connect();
  ready.catch(error => log(`connect failed: ${error.message}`));

  const session = name => {
    let entry = sessions.get(name);
    if (!entry) sessions.set(name, entry = { id: randomUUID(), turn: randomUUID(), timer: undefined });
    clearTimeout(entry.timer);
    entry.timer = setTimeout(() => endTurn(name).catch(() => {}), TURN_IDLE_MS);
    return entry;
  };
  async function endTurn(name, event = 'Stop') {
    const entry = sessions.get(name);
    if (!entry) return false;
    clearTimeout(entry.timer);
    const { id, turn } = entry;
    entry.turn = randomUUID();
    await ready;
    await cua.turnEnded({ sessionId: id, turnId: turn, event });
    return true;
  }

  async function handle(request, signal) {
    lastActivity = Date.now();
    const name = typeof request.session === 'string' && request.session ? request.session : 'default';
    switch (request.op) {
      case 'status':
        return { ok: true, pid: process.pid, lcu: LCU, sessions: [...sessions.keys()] };
      case 'instructions': {
        await ready;
        return { ok: true, instructions: cua.instructions, tools: cua.publicTools() };
      }
      case 'js':
      case 'reset': {
        await ready;
        const entry = session(name);
        const args = request.op === 'js'
          ? { code: request.code, ...(request.timeout_ms ? { timeout_ms: request.timeout_ms } : {}) } : {};
        const result = await cua.call(request.op === 'js' ? 'js' : 'js_reset', args,
          { sessionId: entry.id, turnId: entry.turn, toolCallId: randomUUID(), signal });
        return { ok: true, result };
      }
      case 'end-turn':
        return { ok: true, ended: await endTurn(name) };
      case 'stop':
        setImmediate(shutdown);
        return { ok: true };
      default:
        return { ok: false, error: `unknown op: ${request.op}` };
    }
  }

  rmSync(SOCKET, { force: true });
  const server = createServer({ allowHalfOpen: true }, socket => {
    const abort = new AbortController();
    let buffer = '';
    let answered = false;
    socket.on('data', chunk => {
      buffer += chunk;
      const end = buffer.indexOf('\n');
      if (end < 0 || answered) return;
      answered = true;
      let request;
      try { request = JSON.parse(buffer.slice(0, end)); } catch { request = {}; }
      handle(request, abort.signal)
        .catch(error => ({ ok: false, error: error.message }))
        .then(reply => { lastActivity = Date.now(); if (!socket.destroyed) socket.end(`${JSON.stringify(reply)}\n`); });
    });
    // The caller went away (Ctrl-C, killed): abort its tool call and any approval it is waiting on.
    socket.on('close', () => abort.abort());
    socket.on('error', () => {});
  });
  server.listen(SOCKET, () => log(`listening on ${SOCKET} (pid ${process.pid})`));

  const idle = setInterval(() => { if (Date.now() - lastActivity > EXIT_IDLE_MS) shutdown(); }, 60_000);
  let stopping = false;
  async function shutdown() {
    if (stopping) return;
    stopping = true;
    clearInterval(idle);
    server.close();
    for (const name of sessions.keys()) await endTurn(name).catch(() => {});
    await cua.close().catch(() => {});
    rmSync(SOCKET, { force: true });
    log('stopped');
    process.exit(0);
  }
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

/** Ask the person at the machine with a native dialog; resolves to a choice value, or 'cancel'. */
function askUser(params, request, signal) {
  const meta = params._meta ?? {};
  const warning = [meta.warningSubtitle, meta.subtitle].find(v => typeof v === 'string' && v.trim());
  const prompt = [request.message, warning].filter(Boolean).join('\n\n');
  const labels = request.choices.map(choice => choice.label);
  const script = `
on run argv
  set thePrompt to item 1 of argv
  set theChoices to rest of argv
  activate
  set picked to choose from list theChoices with title "Computer Use approval (cua)" with prompt thePrompt OK button name "OK" cancel button name "Cancel" default items {item 1 of theChoices}
  if picked is false then return ""
  return item 1 of picked
end run`;
  return new Promise(resolve => {
    if (signal?.aborted) return resolve('cancel');
    const child = spawn('/usr/bin/osascript', ['-e', script, prompt, ...labels], { stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    child.stdout.on('data', chunk => { out += chunk; });
    const onAbort = () => child.kill();
    signal?.addEventListener('abort', onAbort, { once: true });
    child.on('error', () => resolve('cancel'));
    child.on('close', () => {
      signal?.removeEventListener('abort', onAbort);
      if (signal?.aborted) return resolve('cancel');
      const choice = request.choices.find(c => c.label === out.trim());
      resolve(choice ? choice.value : 'decline'); // Cancel in the dialog is a refusal
    });
  });
}

function log(line) {
  process.stderr.write(`${new Date().toISOString()} ${line}\n`);
}

// ---------- client ----------

function send(request) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET);
    let data = '';
    socket.on('connect', () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => {
      try { resolve(JSON.parse(data)); } catch { reject(new Error('daemon closed the connection without a reply')); }
    });
    socket.on('error', reject);
  });
}

async function ensureDaemon() {
  try { return await send({ op: 'status' }); } catch {}
  if (!existsSync(join(LCU, 'bin/lcu'))) {
    throw new Error(`LCU is not installed at ${LCU}. Run install.sh, or set LCU_HOME.`);
  }
  mkdirSync(STATE, { recursive: true, mode: 0o700 });
  const out = openSync(LOG, 'a');
  spawn(process.execPath, [process.argv[1], '__daemon'], { detached: true, stdio: ['ignore', out, out] }).unref();
  for (let i = 0; i < 100; i++) {
    await new Promise(r => setTimeout(r, 100));
    try { return await send({ op: 'status' }); } catch {}
  }
  throw new Error(`the daemon did not start; see ${LOG}`);
}

function printResult(result, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  for (const item of result.content ?? []) {
    if (item.type === 'text') process.stdout.write(item.text.endsWith('\n') ? item.text : `${item.text}\n`);
    else if (item.type === 'image') {
      mkdirSync(SHOTS, { recursive: true, mode: 0o700 });
      const ext = (item.mimeType ?? 'image/png').split('/')[1]?.replace('jpeg', 'jpg') || 'png';
      const file = join(SHOTS, `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}.${ext}`);
      writeFileSync(file, Buffer.from(item.data, 'base64'));
      process.stdout.write(`[image: ${file}]\n`);
    } else process.stdout.write(`${JSON.stringify(item)}\n`);
  }
}

async function readStdin() {
  let code = '';
  for await (const chunk of process.stdin) code += chunk;
  return code;
}

async function main(argv) {
  const [command, ...rest] = argv;
  const session = process.env.CUA_SESSION;
  const flag = name => { const i = rest.indexOf(name); if (i < 0) return undefined; return rest.splice(i, 2)[1] ?? ''; };
  const bool = name => { const i = rest.indexOf(name); if (i < 0) return false; rest.splice(i, 1); return true; };
  switch (command) {
    case '__daemon':
      return daemon();
    case undefined: case 'help': case '-h': case '--help':
      process.stdout.write(HELP);
      return 0;
    case '--version':
      process.stdout.write(`cua ${VERSION}\n`);
      return 0;
    case 'apps': case 'doctor':
      return new Promise(resolve => spawn(join(LCU, 'bin/lcu'), [command, ...rest], { stdio: 'inherit' })
        .on('close', status => resolve(status ?? 1)));
    case 'start': {
      const status = await ensureDaemon();
      process.stdout.write(`daemon running (pid ${status.pid})\n`);
      return 0;
    }
    case 'status':
      try {
        const status = await send({ op: 'status' });
        process.stdout.write(`daemon running (pid ${status.pid}); LCU ${status.lcu}; sessions: ${status.sessions.join(', ') || 'none'}\n`);
        return 0;
      } catch {
        process.stdout.write('daemon not running\n');
        return 3;
      }
    case 'stop':
      try { await send({ op: 'stop' }); process.stdout.write('daemon stopped\n'); } catch { process.stdout.write('daemon not running\n'); }
      return 0;
    case 'instructions': {
      await ensureDaemon();
      const reply = await send({ op: 'instructions', session });
      if (!reply.ok) throw new Error(reply.error);
      process.stdout.write(`${reply.instructions}\n`);
      for (const tool of reply.tools) {
        process.stdout.write(`\n## Tool \`${tool.name}\` (run with: cua ${tool.name === 'js' ? 'js CODE' : 'reset'})\n\n${tool.description ?? ''}\n`);
        if (tool.inputSchema) process.stdout.write(`\nInput schema: ${JSON.stringify(tool.inputSchema)}\n`);
      }
      return 0;
    }
    case 'js': case 'reset': {
      let code;
      const json = bool('--json');
      const timeout = flag('--timeout');
      if (command === 'js') {
        const file = flag('-f');
        if (file !== undefined) code = file === '-' ? await readStdin() : readFileSync(file, 'utf8');
        else if (rest[0] === '-' || (!rest.length && !process.stdin.isTTY)) code = await readStdin();
        else code = rest.join(' ');
        if (!code.trim()) { process.stderr.write('cua js: no code given\n'); return 2; }
      }
      await ensureDaemon();
      const reply = await send({ op: command, code, session, ...(timeout ? { timeout_ms: Number(timeout) } : {}) });
      if (!reply.ok) throw new Error(reply.error);
      printResult(reply.result, json);
      return reply.result.isError ? 1 : 0;
    }
    case 'end-turn': {
      try {
        const reply = await send({ op: 'end-turn', session });
        if (!reply.ok) throw new Error(reply.error);
      } catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ECONNREFUSED') return 0; // no daemon, nothing to end
        throw error;
      }
      return 0;
    }
    default:
      process.stderr.write(`cua: unknown command ${command}\n\n${HELP}`);
      return 2;
  }
}

main(process.argv.slice(2)).then(status => {
  if (typeof status === 'number') process.exit(status);
}, error => {
  process.stderr.write(`cua: ${error.message}\n`);
  process.exit(2);
});
