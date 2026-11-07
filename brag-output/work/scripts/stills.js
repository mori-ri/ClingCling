const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const [page_, out, ...times] = process.argv.slice(2);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('console', (m) => console.log('console:', m.text()));
  page.on('pageerror', (e) => console.log('pageerror:', e.message));
  await page.goto('file://' + path.resolve(page_));
  await page.evaluate(() => window.ready);
  for (const t of times) {
    await page.evaluate((t) => window.render(t), Number(t));
    await page.screenshot({ path: `${out}/t${String(t).padStart(5, '0')}.jpg`, type: 'jpeg', quality: 80 });
  }
  await browser.close();
})();
