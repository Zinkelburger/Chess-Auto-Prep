#!/usr/bin/env node
/**
 * End-to-end test for the MCP stdio shim.
 *
 * Spawns the real shim against a stub HTTP server that speaks the same
 * contract as `PrepServer`, then drives an actual JSON-RPC handshake over its
 * stdin/stdout. This is the only thing that proves the two halves of the
 * bridge agree — the Dart side is covered by `prep_server_test.dart`, but
 * nothing else checks that the shim can talk to it.
 *
 * Zero dependencies. Run with:
 *     node tools/mcp/test_chess_prep_mcp.mjs
 */

import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const SHIM = join(dirname(fileURLToPath(import.meta.url)), 'chess_prep_mcp.mjs');
const TOKEN = 'test-token-abc123';

// Non-ASCII on purpose: the Dart server shipped a latin1 encoding bug that
// made exactly this content fail, so the shim must handle it too.
const TOOLS = [
  {
    name: 'directory_search',
    description: 'Look up a player in the USCF → chess.com directory — partial coverage.',
    inputSchema: {
      type: 'object',
      properties: { uscf_id: { type: 'string', description: 'USCF member ID.' } },
      additionalProperties: false,
    },
  },
];

let lastCall = null;
let seenAuth = null;

function startStub() {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      seenAuth = req.headers.authorization ?? null;
      if (seenAuth !== `Bearer ${TOKEN}`) {
        res.writeHead(401, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: 'Unauthorized' }));
        return;
      }

      if (req.url === '/tools' && req.method === 'GET') {
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ tools: TOOLS }));
        return;
      }

      if (req.url === '/call' && req.method === 'POST') {
        let body = '';
        req.on('data', (c) => (body += c));
        req.on('end', () => {
          lastCall = JSON.parse(body);
          res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
          if (lastCall.name === 'boom') {
            res.end(JSON.stringify({ ok: false, error: 'Supply one of uscf_id, name.' }));
          } else {
            res.end(
              JSON.stringify({
                ok: true,
                result: { found: true, entry: { chesscom_username: 'someone' } },
              }),
            );
          }
        });
        return;
      }

      res.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: 'nope' }));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

/** Drives the shim over stdio, resolving responses by JSON-RPC id. */
class Shim {
  constructor(endpointFile) {
    this.proc = spawn('node', [SHIM], {
      env: { ...process.env, CHESS_PREP_MCP_ENDPOINT: endpointFile },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.pending = new Map();
    this.stderr = '';
    this.proc.stderr.on('data', (d) => (this.stderr += d));

    createInterface({ input: this.proc.stdout }).on('line', (line) => {
      if (!line.trim()) return;
      const msg = JSON.parse(line);
      const resolve = this.pending.get(msg.id);
      if (resolve) {
        this.pending.delete(msg.id);
        resolve(msg);
      }
    });
  }

  send(id, method, params) {
    return new Promise((resolve, reject) => {
      this.pending.set(id, resolve);
      this.proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
      setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), 5000);
    });
  }

  notify(method, params) {
    this.proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method, params })}\n`);
  }

  kill() {
    this.proc.kill();
  }
}

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push([true, name]);
    console.log(`  ok   ${name}`);
  } catch (e) {
    results.push([false, name]);
    console.log(`  FAIL ${name}\n       ${e.message}`);
  }
}

async function main() {
  const server = await startStub();
  const port = server.address().port;
  const dir = mkdtempSync(join(tmpdir(), 'mcp-shim-test-'));
  const endpointFile = join(dir, 'mcp_endpoint.json');
  writeFileSync(
    endpointFile,
    JSON.stringify({ url: `http://127.0.0.1:${port}`, token: TOKEN }),
  );

  const shim = new Shim(endpointFile);
  console.log('MCP stdio shim');

  await check('initialize returns serverInfo and echoes the protocol version', async () => {
    const r = await shim.send(1, 'initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'test', version: '1' },
    });
    assert.equal(r.result.protocolVersion, '2025-06-18');
    assert.equal(r.result.serverInfo.name, 'chess-prep');
    assert.ok(r.result.capabilities.tools);
  });

  await check('initialize without a version falls back to a known one', async () => {
    const r = await shim.send(2, 'initialize', {});
    assert.match(r.result.protocolVersion, /^\d{4}-\d{2}-\d{2}$/);
  });

  await check('the initialized notification is not answered', async () => {
    shim.notify('notifications/initialized', {});
    // If the shim replied to a notification it would break strict clients.
    // Prove the stream is still healthy by round-tripping a real request.
    const r = await shim.send(3, 'ping', {});
    assert.deepEqual(r.result, {});
  });

  await check('tools/list proxies the app and preserves non-ASCII', async () => {
    const r = await shim.send(4, 'tools/list', {});
    assert.equal(r.result.tools.length, 1);
    assert.equal(r.result.tools[0].name, 'directory_search');
    assert.ok(r.result.tools[0].description.includes('→'), 'arrow survived');
    assert.equal(r.result.tools[0].inputSchema.type, 'object');
  });

  await check('the bearer token is sent', () => {
    assert.equal(seenAuth, `Bearer ${TOKEN}`);
  });

  await check('tools/call forwards name and arguments', async () => {
    const r = await shim.send(5, 'tools/call', {
      name: 'directory_search',
      arguments: { uscf_id: '12345678' },
    });
    assert.deepEqual(lastCall, {
      name: 'directory_search',
      arguments: { uscf_id: '12345678' },
    });
    assert.equal(r.result.isError, undefined);
    const payload = JSON.parse(r.result.content[0].text);
    assert.equal(payload.entry.chesscom_username, 'someone');
  });

  await check('a tool-level error becomes isError content, not a transport error', async () => {
    const r = await shim.send(6, 'tools/call', { name: 'boom', arguments: {} });
    assert.equal(r.error, undefined, 'must not be a JSON-RPC error');
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /Supply one of/);
  });

  await check('tools/call with no name is a protocol error', async () => {
    const r = await shim.send(7, 'tools/call', {});
    assert.equal(r.error.code, -32602);
  });

  await check('an unknown method reports method-not-found', async () => {
    const r = await shim.send(8, 'nonsense/method', {});
    assert.equal(r.error.code, -32601);
  });

  await check('malformed input does not kill the process', async () => {
    shim.proc.stdin.write('{not json\n');
    const r = await shim.send(9, 'ping', {});
    assert.deepEqual(r.result, {});
  });

  shim.kill();

  // A second shim pointed at a dead app must explain itself rather than hang.
  await check('a stopped app produces an actionable error', async () => {
    const deadDir = mkdtempSync(join(tmpdir(), 'mcp-shim-dead-'));
    const deadFile = join(deadDir, 'mcp_endpoint.json');
    writeFileSync(deadFile, JSON.stringify({ url: 'http://127.0.0.1:1', token: 'x' }));

    const dead = new Shim(deadFile);
    const r = await dead.send(1, 'tools/list', {});
    assert.ok(r.error, 'expected an error');
    assert.match(r.error.message, /not reachable|Agent bridge/);
    dead.kill();
    rmSync(deadDir, { recursive: true, force: true });
  });

  await check('a missing descriptor names where it looked', async () => {
    const gone = new Shim(join(dir, 'does_not_exist.json'));
    const r = await gone.send(1, 'tools/list', {});
    assert.ok(r.error);
    assert.match(r.error.message, /does_not_exist\.json|not reachable/);
    gone.kill();
  });

  server.close();
  rmSync(dir, { recursive: true, force: true });

  const failed = results.filter(([ok]) => !ok);
  console.log(
    `\n${results.length - failed.length}/${results.length} passed` +
      (failed.length ? ` — ${failed.length} FAILED` : ''),
  );
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
