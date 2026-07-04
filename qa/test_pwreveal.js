// Addendum Part 2 §3 check — one-time password-reveal modal.
// Does NOT create or reset any real account (no admin_create_user /
// admin_update_credentials RPC call). It calls openPwReveal() directly,
// which is exactly what those functions call after a real RPC succeeds —
// this verifies the modal/copy/clear behavior in isolation, safely.

const { chromium } = require('playwright');
const BASE = 'http://localhost:' + (Number(process.env.QA_PORT) || 8788);

(async () => {
  const failures = [];
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(BASE + '/index.html');
  await page.waitForTimeout(800);

  // Enter the portal the same way a real admin would (client-side-only fake
  // session, no real Supabase call — same safe technique as test_admin_nav.js)
  // so the landing page is hidden and the modal is tested exactly as it
  // appears in real usage, not floating behind the marketing overlay.
  await page.evaluate(() => {
    session = { uid: 'qa-fake-admin', role: 'admin', email: 'admin@motion.edu', name: 'QA Admin' };
    applySession();
  });
  await page.waitForTimeout(300);

  await page.evaluate(() => openPwReveal('newstudent42', 'Xk9#mQ2p'));
  await page.waitForTimeout(150);

  const state1 = await page.evaluate(() => ({
    open: document.getElementById('pwreveal-modal-overlay').classList.contains('open'),
    user: document.getElementById('pwreveal-username').value,
    pass: document.getElementById('pwreveal-password').value,
  }));
  if (!state1.open) failures.push('modal did not open');
  if (state1.user !== 'newstudent42') failures.push('username field wrong: ' + state1.user);
  if (state1.pass !== 'Xk9#mQ2p') failures.push('password field wrong: ' + state1.pass);

  // grant clipboard permission so the copy button's writeText() resolves
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.click('button[onclick*="pwreveal-password"]');
  await page.waitForTimeout(150);
  const copiedNote = await page.evaluate(() => document.getElementById('pwreveal-copied').textContent);
  if (!copiedNote.includes('Copied')) failures.push('copy confirmation text missing: ' + JSON.stringify(copiedNote));
  const clip = await page.evaluate(() => navigator.clipboard.readText());
  if (clip !== 'Xk9#mQ2p') failures.push('clipboard content wrong: ' + JSON.stringify(clip));

  await page.click('#pwreveal-modal-overlay .modal-close');
  await page.waitForTimeout(150);
  const state2 = await page.evaluate(() => ({
    open: document.getElementById('pwreveal-modal-overlay').classList.contains('open'),
    user: document.getElementById('pwreveal-username').value,
    pass: document.getElementById('pwreveal-password').value,
  }));
  if (state2.open) failures.push('modal did not close');
  if (state2.user !== '' || state2.pass !== '') failures.push('fields not cleared after close: ' + JSON.stringify(state2));

  await browser.close();

  if (failures.length) {
    console.error('\nFAILURES:');
    failures.forEach(f => console.error(' - ' + f));
    process.exit(1);
  }
  console.log('ALL PASSWORD-REVEAL MODAL CHECKS PASSED (' + 4 + ' assessed states)');
})().catch(e => { console.error('FATAL:', e); process.exit(1); });
