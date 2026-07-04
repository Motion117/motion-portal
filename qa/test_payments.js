// Addendum Part 2 §5 check — admin Payments record-keeping screen.
// supabase/admin_payments.sql is reviewable-but-unapplied (same rule as every
// other privilege-granting SQL file in this project), so this verifies the
// UI renders and fails gracefully, not the real RPC round trip.

const { chromium } = require('playwright');
const BASE = 'http://localhost:' + (Number(process.env.QA_PORT) || 8788);

(async () => {
  const failures = [];
  const check = (cond, label) => { console.log((cond ? 'PASS' : 'FAIL') + ' - ' + label); if (!cond) failures.push(label); };

  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('pageerror', e => failures.push('JS error: ' + e.message));
  await page.goto(BASE + '/index.html');
  await page.waitForTimeout(800);

  await page.evaluate(() => {
    session = { uid: 'qa-fake-admin', role: 'admin', email: 'admin@motion.edu', name: 'QA Admin' };
    applySession();
  });
  await page.waitForTimeout(300);

  const navVisible = await page.evaluate(() => {
    const el = document.querySelector('[data-id="admin-payments"]');
    return !!el && getComputedStyle(el).display !== 'none';
  });
  check(navVisible, 'admin: Payments nav item visible');

  await page.evaluate(() => navTo('admin-payments'));
  await page.waitForTimeout(2500);

  const rateVal = await page.evaluate(() => document.getElementById('pay-rate-in')?.value);
  check(rateVal === '600000', 'payments: rate field defaults to 600000 when backend absent :: got=' + rateVal);

  const periodVal = await page.evaluate(() => document.getElementById('pay-period-in')?.value);
  check(/^\d{4}-\d{2}$/.test(periodVal || ''), 'payments: period defaults to current YYYY-MM :: got=' + periodVal);

  const statusText = await page.evaluate(() => document.getElementById('pay-status-list')?.textContent || '');
  check(/not installed/i.test(statusText), 'payments: status list shows clear "backend not installed" message :: got=' + JSON.stringify(statusText.slice(0, 80)));

  // Rate-save RPC failure should surface a clear toast, not crash
  await page.click('button[onclick="adminSaveMonthlyRate()"]');
  await page.waitForTimeout(3000);
  const toastText = await page.evaluate(() => document.getElementById('toast')?.textContent || '');
  check(/not installed/i.test(toastText), 'payments: save-rate RPC failure surfaces a clear toast :: got=' + JSON.stringify(toastText));

  const noJsErrors = failures.filter(f => f.startsWith('JS error')).length === 0;
  check(noJsErrors, 'no uncaught JS errors during payments flow');

  await browser.close();

  console.log('\n6 checks, ' + failures.length + ' failed');
  if (failures.length) { failures.forEach(f => console.error(' - ' + f)); process.exit(1); }
})().catch(e => { console.error('FATAL:', e); process.exit(1); });
