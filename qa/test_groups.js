// Addendum Part 2 §2 check — groups-within-levels client-side wiring.
// supabase/admin_groups.sql is a REVIEWABLE file, not auto-applied (same rule
// as admin_role.sql/admin_freeze.sql) — so this test cannot exercise the real
// RPCs yet. It verifies: (a) the fallback GROUPS list still renders every
// picker correctly before/without a live `groups` table, (b) the level->group
// cascading pickers wire up correctly, (c) admin RPC calls fail gracefully
// with a clear "backend not installed" message instead of breaking the UI.

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

  // ── Signup form: level -> group cascading picker (pre-auth, fallback data) ──
  await page.click('#ld-login-link');
  await page.waitForTimeout(150);
  await page.click('text=New student? Create an account');
  await page.waitForTimeout(150);
  const signupLevelCount = await page.evaluate(() => document.getElementById('signup-level').options.length);
  check(signupLevelCount === 5, 'signup: level picker has all 5 fixed levels :: got=' + signupLevelCount);
  const signupGroupBefore = await page.evaluate(() => document.getElementById('signup-group').options.length);
  check(signupGroupBefore >= 1, 'signup: group picker populated for default level :: got=' + signupGroupBefore);
  await page.selectOption('#signup-level', 'ielts');
  await page.waitForTimeout(100);
  const signupGroupAfter = await page.evaluate(() => document.getElementById('signup-group').options[0]?.textContent);
  check(signupGroupAfter === 'IELTS Prep C1', 'signup: switching level updates group options :: got=' + signupGroupAfter);
  await page.evaluate(() => hideLogin());
  await page.waitForTimeout(150);

  // ── Enter portal as a fake admin (client-side-only session, no real RPC —
  // same safe technique as test_admin_nav.js / test_pwreveal.js) ──
  await page.evaluate(() => {
    session = { uid: 'qa-fake-admin', role: 'admin', email: 'admin@motion.edu', name: 'QA Admin' };
    applySession();
  });
  await page.waitForTimeout(300);
  await page.evaluate(() => { navTo('admin'); });
  await page.waitForTimeout(500);

  const admLevelCount = await page.evaluate(() => document.getElementById('adm-new-level').options.length);
  check(admLevelCount === 5, 'admin create-account: level picker has all 5 fixed levels :: got=' + admLevelCount);
  const admGroupBefore = await page.evaluate(() => document.getElementById('adm-new-group').options.length);
  check(admGroupBefore >= 1, 'admin create-account: group picker populated for default level :: got=' + admGroupBefore);

  const groupsCardVisible = await page.evaluate(() => {
    const el = document.getElementById('adm-groups-list');
    return !!el && el.offsetParent !== null;
  });
  check(groupsCardVisible, 'admin: Groups management card is visible');

  // admin_groups.sql not applied yet in this environment -> RPC calls must
  // fail gracefully with a clear message, not throw / break the page.
  await page.fill('#adm-grp-new-name', 'QA Test Group');
  await page.click('button[onclick="adminCreateGroup()"]');
  await page.waitForTimeout(3000);
  const toastText = await page.evaluate(() => document.getElementById('toast')?.textContent || '');
  check(/not installed/i.test(toastText) || /could not/i.test(toastText), 'admin: create-group RPC failure surfaces a clear toast, no crash :: got=' + JSON.stringify(toastText));

  const noJsErrors = failures.filter(f => f.startsWith('JS error')).length === 0;
  check(noJsErrors, 'no uncaught JS errors during groups flow');

  await browser.close();

  console.log('\n' + (5 + 1) + ' checks, ' + failures.length + ' failed');
  if (failures.length) { failures.forEach(f => console.error(' - ' + f)); process.exit(1); }
})().catch(e => { console.error('FATAL:', e); process.exit(1); });
