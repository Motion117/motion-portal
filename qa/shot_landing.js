// Scratch utility — full-page screenshots of the landing page in a matrix of
// viewport × theme × language. Usage: QA_PORT=8791 node qa/shot_landing.js <outdir> [tag]
const { chromium } = require('playwright');
const path = require('path');
const BASE = 'http://localhost:' + (Number(process.env.QA_PORT) || 8788);
const OUT = process.argv[2] || '.';
const TAG = process.argv[3] || 'before';

(async () => {
  const browser = await chromium.launch();
  const matrix = [
    { w: 1440, h: 900, name: 'desktop' },
    { w: 390, h: 844, name: 'mobile' },
  ];
  for (const vp of matrix) {
    for (const theme of ['dark', 'light']) {
      for (const lang of ['ru', 'en', 'uz']) {
        // skip some combos to keep the set manageable: en/uz only in dark desktop
        if (lang !== 'ru' && !(theme === 'dark' && vp.name === 'desktop')) continue;
        const ctx = await browser.newContext({ viewport: { width: vp.w, height: vp.h } });
        const page = await ctx.newPage();
        await page.goto(BASE + '/index.html');
        await page.waitForTimeout(2200);
        await page.evaluate(({ theme, lang }) => {
          document.documentElement.setAttribute('data-theme', theme);
          ldSetLang(lang);
        }, { theme, lang });
        await page.waitForTimeout(600);
        // force all reveal-on-scroll elements visible for a full-page shot
        await page.evaluate(() => document.querySelectorAll('#landing-page .rv').forEach(el => el.classList.add('in')));
        await page.waitForTimeout(400);
        const el = await page.$('#landing-page');
        const file = path.join(OUT, `${TAG}-${vp.name}-${theme}-${lang}.png`);
        // #landing-page is the scroll container (position:fixed) — screenshot it via full page after expanding
        await page.evaluate(() => {
          const lp = document.getElementById('landing-page');
          lp.style.position = 'static';
          lp.style.overflow = 'visible';
          lp.style.height = 'auto';
          document.body.style.overflow = 'visible';
        });
        await page.waitForTimeout(300);
        await page.screenshot({ path: file, fullPage: true });
        console.log('saved', file);
        await ctx.close();
      }
    }
  }
  await browser.close();
})().catch(e => { console.error('FATAL:', e); process.exit(1); });
