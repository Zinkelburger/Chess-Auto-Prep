#!/usr/bin/env node
/**
 * MCP stdio bridge for Chess Auto Prep.
 *
 * The Flutter desktop app is a GUI process, not something an MCP client can
 * spawn — and you *want* it long-lived anyway, because the engine pool, Maia
 * session and eval cache are expensive to warm and are reused across every
 * opponent in a field. So the app hosts a loopback HTTP server and this
 * script is the thin stdio shim in front of it.
 *
 * Zero dependencies. Node 18+.
 *
 * Setup
 * -----
 * 1. In Chess Auto Prep: Settings → Agent bridge (MCP) → enable.
 * 2. Register this file with your MCP client, e.g. for Claude Code:
 *
 *      claude mcp add chess-prep -- node /abs/path/to/tools/mcp/chess_prep_mcp.mjs
 *
 *    or in a Cursor / Claude Desktop config:
 *
 *      { "mcpServers": {
 *          "chess-prep": {
 *            "command": "node",
 *            "args": ["/abs/path/to/tools/mcp/chess_prep_mcp.mjs"]
 *          }
 *      }}
 *
 * The app writes its URL and token to `mcp_endpoint.json` in its support
 * directory; this script finds that automatically. Override with
 * CHESS_PREP_MCP_ENDPOINT (a file path) or CHESS_PREP_URL + CHESS_PREP_TOKEN.
 */

import { readFileSync, existsSync } from 'node:fs';
import { homedir, platform } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const SERVER_NAME = 'chess-prep';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2024-11-05';
const ENDPOINT_FILE = 'mcp_endpoint.json';

// ── Locating the app ────────────────────────────────────────────────────────

/**
 * Candidate support directories, matching path_provider's
 * getApplicationSupportDirectory() per platform.
 *
 * path_provider keys this off the platform's *application identifier*, not the
 * Dart package name: on Linux the CMake APPLICATION_ID
 * (`com.example.chess_auto_prep`), on macOS the bundle id
 * (`com.example.chessAutoPrep`). The package name is listed only as a fallback
 * — it is not where the app writes.
 */
function candidateEndpointFiles() {
  const explicit = process.env.CHESS_PREP_MCP_ENDPOINT;
  if (explicit) return [explicit];

  const home = homedir();
  const dirs = [];

  switch (platform()) {
    case 'darwin': {
      const base = join(home, 'Library', 'Application Support');
      dirs.push(join(base, 'com.example.chessAutoPrep'), join(base, 'chess_auto_prep'));
      break;
    }
    case 'win32': {
      const appData = process.env.APPDATA || join(home, 'AppData', 'Roaming');
      dirs.push(join(appData, 'com.example', 'chess_auto_prep'), join(appData, 'chess_auto_prep'));
      break;
    }
    default: {
      const dataHome = process.env.XDG_DATA_HOME || join(home, '.local', 'share');
      dirs.push(join(dataHome, 'com.example.chess_auto_prep'), join(dataHome, 'chess_auto_prep'));
      break;
    }
  }

  return dirs.map((d) => join(d, ENDPOINT_FILE));
}

function resolveEndpoint() {
  if (process.env.CHESS_PREP_URL) {
    return {
      url: process.env.CHESS_PREP_URL.replace(/\/$/, ''),
      token: process.env.CHESS_PREP_TOKEN || '',
    };
  }

  for (const file of candidateEndpointFiles()) {
    if (!existsSync(file)) continue;
    try {
      const parsed = JSON.parse(readFileSync(file, 'utf8'));
      if (parsed.url) {
        return { url: String(parsed.url).replace(/\/$/, ''), token: parsed.token || '' };
      }
    } catch {
      // Corrupt or half-written descriptor: keep looking.
    }
  }
  return null;
}

const NOT_RUNNING =
  'Chess Auto Prep is not reachable. Start the app and enable ' +
  'Settings → Agent bridge (MCP). Checked: ' +
  candidateEndpointFiles().join(', ');

async function callApp(path, options = {}) {
  const endpoint = resolveEndpoint();
  if (!endpoint) throw new Error(NOT_RUNNING);

  const headers = { 'content-type': 'application/json' };
  if (endpoint.token) headers.authorization = `Bearer ${endpoint.token}`;

  let response;
  try {
    response = await fetch(`${endpoint.url}${path}`, { ...options, headers });
  } catch (cause) {
    throw new Error(`${NOT_RUNNING} (${cause.message})`);
  }

  if (response.status === 401) {
    throw new Error(
      'Rejected by Chess Auto Prep (bad token). Toggle the agent bridge off ' +
        'and on in Settings to mint a fresh one.',
    );
  }
  if (!response.ok) {
    throw new Error(`Chess Auto Prep returned HTTP ${response.status}.`);
  }
  return response.json();
}

// ── JSON-RPC plumbing ───────────────────────────────────────────────────────

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

/** Tool results are text content blocks; we hand back pretty JSON. */
function textResult(value, isError = false) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: 'text', text }], ...(isError ? { isError: true } : {}) };
}

async function handleInitialize(id, params) {
  // Echo the client's protocol version when it supplies one, so we stay
  // compatible across MCP revisions without tracking each release.
  const requested = params?.protocolVersion;
  reply(id, {
    protocolVersion: typeof requested === 'string' ? requested : DEFAULT_PROTOCOL,
    capabilities: { tools: { listChanged: false } },
    serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
  });
}

async function handleToolsList(id) {
  try {
    const data = await callApp('/tools', { method: 'GET' });
    reply(id, { tools: data.tools ?? [] });
  } catch (error) {
    // Returning an empty list would look like "the app has no tools"; a
    // protocol error makes the real cause visible in the client.
    replyError(id, -32603, error.message);
  }
}

async function handleToolsCall(id, params) {
  const name = params?.name;
  if (!name) {
    replyError(id, -32602, 'Missing tool name.');
    return;
  }

  try {
    const data = await callApp('/call', {
      method: 'POST',
      body: JSON.stringify({ name, arguments: params.arguments ?? {} }),
    });

    // Tool-level failures come back as data, not transport errors, so the
    // model can read and correct them.
    if (data && data.ok === false) {
      reply(id, textResult(`Error: ${data.error}`, true));
      return;
    }
    reply(id, textResult(data?.result ?? data));
  } catch (error) {
    reply(id, textResult(`Error: ${error.message}`, true));
  }
}

async function dispatch(message) {
  const { id, method, params } = message;

  // Notifications carry no id and must not be answered.
  if (id === undefined || id === null) return;

  switch (method) {
    case 'initialize':
      return handleInitialize(id, params);
    case 'tools/list':
      return handleToolsList(id);
    case 'tools/call':
      return handleToolsCall(id, params);
    case 'ping':
      return reply(id, {});
    default:
      return replyError(id, -32601, `Method not found: ${method}`);
  }
}

const rl = createInterface({ input: process.stdin, terminal: false });

rl.on('line', async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;

  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
    return;
  }

  try {
    await dispatch(message);
  } catch (error) {
    if (message?.id !== undefined && message?.id !== null) {
      replyError(message.id, -32603, error.message);
    }
  }
});

rl.on('close', () => process.exit(0));
