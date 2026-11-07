// 指定した範囲のフレームを PNG で書き出す。描画は render(t) の純粋な関数
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const [page_, out, fps, dur, from = '0', to] = process.argv.slice(2);
  const total = Math.round(Number(dur) * Number(fps));
  const end = to ? Number(to) : total;
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.log('pageerror:', e.message));
  await page.goto('file://' + path.resolve(page_));
  await page.evaluate(() => window.ready);
  for (let f = Number(from); f < end; f++) {
    await page.evaluate((t) => window.render(t), f / Number(fps));
    await page.screenshot({ path: `${out}/f${String(f).padStart(4, '0')}.png`, type: 'png' });
  }
  await browser.close();
})();
