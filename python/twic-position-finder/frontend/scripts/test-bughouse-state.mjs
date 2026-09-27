import { build } from 'esbuild';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
const result = await build({
  entryPoints: [fileURLToPath(new URL('../tests/bughouse-state.ts', import.meta.url))],
  bundle: true, write: false, platform: 'node', format: 'esm', target: 'node22',
});
const dir = await mkdtemp(path.join(tmpdir(), 'bughouse-state-test-'));
try {
  const file = path.join(dir, 'test.mjs');
  await writeFile(file, result.outputFiles[0].text);
  await import(pathToFileURL(file).href);
} finally { await rm(dir, { recursive: true, force: true }); }
