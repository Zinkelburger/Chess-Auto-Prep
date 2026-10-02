// Built pages + real API + an isolated snapshot database. No production writes.
// node scripts/test-bughouse-expectimax.mjs <native-smoke.db> <screenshots-dir>
import assert from 'node:assert/strict';
import path from 'node:path';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import os from 'node:os';
import { spawn } from 'node:child_process';
import puppeteer from 'puppeteer-core';
const [database, output] = process.argv.slice(2).map(p => path.resolve(p));
const temp = await mkdtemp(path.join(os.tmpdir(), 'expectimax-browser-'));
await mkdir(output, { recursive: true });
const server = spawn('python3', ['-u', '-c', `
import os,sqlite3
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import uvicorn,bughousedb
source=sqlite3.connect(os.environ['FIXTURE_DB'])
dest=sqlite3.connect(os.environ['BUGHOUSE_EXPECTIMAX_PATH'])
source.backup(dest);dest.close();source.close()
app=FastAPI()
app.add_middleware(CORSMiddleware,allow_origins=['*'],allow_methods=['*'],allow_headers=['*'])
app.include_router(bughousedb.router)
app.mount('/',StaticFiles(directory='frontend/dist',html=True))
uvicorn.run(app,host='127.0.0.1',port=18764,log_level='warning')
`], { cwd: path.resolve('..'), env: { ...process.env, FIXTURE_DB: database,
  BUGHOUSEDB_PATH: path.join(temp, 'book.db'), BUGHOUSE_EXPECTIMAX_PATH: path.join(temp, 'expected.db') }, stdio: ['ignore', 'inherit', 'inherit'] });
let browser;
try {
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch('http://127.0.0.1:18764/bughouse/')).ok) break; } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  browser = await puppeteer.launch({ executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', headless: true, args: ['--disable-dev-shm-usage'] });
  const page = await browser.newPage();
  await page.evaluateOnNewDocument(() => localStorage.clear());
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('requestfailed', request => console.error('Request failed:', request.url(), request.failure()?.errorText));
  await page.setRequestInterception(true);
  page.on('request', request => {
    const url = new URL(request.url());
    if (url.pathname.startsWith('/api/bughousedb')) {
      void request.continue({ url: `http://127.0.0.1:18764${url.pathname}${url.search}` });
    } else void request.continue();
  });
  for (const route of ['bughouse', 'bughousedb']) {
    for (const [device, width, height] of [['desktop', 1360, 1000], ['mobile', 390, 844]]) {
      await page.setViewport({ width, height, deviceScaleFactor: 1 });
      await page.goto(`http://127.0.0.1:18764/${route}/`, { waitUntil: 'networkidle0' });
      try { await page.waitForSelector('.bh-expectimax-table tbody tr'); } catch (error) {
        console.error(route, device, await page.$eval('body', x => x.innerText), errors);
        throw error;
      }
      assert.equal(await page.$$eval('.bh-expectimax-table', x => x.length), 2);
      assert.ok(await page.$eval('.bh-expectimax', x => x.textContent.includes('Exp White') && x.textContent.includes('Exp Black')));
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${route} ${device}: no horizontal page overflow`);
      await page.screenshot({ path: path.join(output, `${route}-${device}.png`), fullPage: true });
      await page.$eval('.bh-expectimax', x => x.scrollIntoView());
      await page.screenshot({ path: path.join(output, `${route}-${device}-table.png`) });
      if (device === 'desktop') {
        await page.focus('.bh-expectimax-table tbody tr');
        await page.keyboard.press('Enter');
        await page.waitForFunction(() => !document.querySelector('.bh-expectimax-table'));
        await page.waitForFunction(() => document.querySelector('.bh-expectimax').textContent.includes('Not yet'));
        assert.match(await page.$eval('.bh-expectimax', x => x.textContent), /Not yet/);
        // Navigation must not leave scores from the previous position behind.
        await page.evaluate(() => localStorage.clear());
      }
    }
  }
  assert.deepEqual(errors, []);
  console.log('Both web pages: both boards/colours, keyboard play, stale-score clearing and desktop/mobile layout passed.');
} finally {
  await browser?.close();
  server.kill('SIGTERM');
  await new Promise(resolve => server.once('exit', resolve));
  await rm(temp, { recursive: true, force: true });
}
