import { build } from 'esbuild';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
// Each suite is its own bundle: Bughouse Single Board switches the shared tree to bughouse rules.
const dir = await mkdtemp(path.join(tmpdir(), 'crazyhouse-test-'));
try {
  for (const suite of ['crazyhouse', 'bughouse-single']) {
    const result = await build({
      entryPoints: [fileURLToPath(new URL(`../tests/${suite}.ts`, import.meta.url))],
      bundle: true, write: false, platform: 'node', format: 'esm', target: 'node22',
    });
    const file = path.join(dir, `${suite}.mjs`);
    await writeFile(file, result.outputFiles[0].text);
    await import(pathToFileURL(file).href);
  }
} finally { await rm(dir, { recursive: true, force: true }); }
