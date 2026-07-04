const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const results = [];
  const check = (name, cond, extra) => { results.push({ name, ok: !!cond, extra }); console.log((cond ? 'PASS' : 'FAIL') + ' - ' + name + (extra ? ' :: ' + extra : '')); };

  await page.goto('http://localhost:8791/index.html');
  await page.waitForTimeout(2200);

  // Log in as the real demo teacher first, visit Profile (populates the
  // teacher-only DOM section), THEN switch to a client-side-only admin
  // session with no page reload — this is exactly the stale-DOM scenario
  // the §1 bug was about (admin inheriting a previous role's leftover DOM).
  await page.click('#ld-login-link');
  await page.waitForTimeout(150);
  await page.fill('#login-user', 'teacher');
  await page.fill('#login-pass', 'teacher2026');
  await page.click('.login-btn.primary');
  await page.waitForTimeout(3000);
  await page.evaluate(() => navTo('profile'));
  await page.waitForTimeout(500);
  const teacherSectionShown = await page.evaluate(() => document.getElementById('profile-teacher-section').style.display !== 'none');
  check('teacher profile: teacher section visible before switch', teacherSectionShown);

  // Now switch to a fake admin session client-side only (no DB write, no
  // real Supabase call) purely to verify the UI's role handling.
  await page.evaluate(() => {
    session = { role: 'admin', name: 'Test Admin', email: 'admin@motion.edu', uid: 'fake-admin-uid' };
    saveStore({ session });
    applySession();
    navTo('profile');
  });
  await page.waitForTimeout(500);

  const teacherSecHidden = await page.evaluate(() => document.getElementById('profile-teacher-section').style.display === 'none');
  const studentSecHidden = await page.evaluate(() => document.getElementById('profile-student-section').style.display === 'none');
  const adminSecShown = await page.evaluate(() => document.getElementById('profile-admin-section').style.display !== 'none');
  check('§1 fix: admin profile hides leftover teacher section', teacherSecHidden);
  check('§1 fix: admin profile hides student section', studentSecHidden);
  check('§1 fix: admin profile shows its own section', adminSecShown);

  const payAmountVisible = await page.evaluate(() => {
    const el = document.getElementById('profile-student-section');
    return el && getComputedStyle(el).display !== 'none';
  });
  check('§1 fix: no fake student payment data visible to admin', !payAmountVisible);

  // §4: Materials/Announcements hidden from admin nav via data-hide-admin
  const materialsVisible = await page.evaluate(() => {
    const el = document.querySelector('[data-id="materials"]');
    return el && getComputedStyle(el).display !== 'none';
  });
  const announceVisible = await page.evaluate(() => {
    const el = document.querySelector('[data-id="announce"]');
    return el && getComputedStyle(el).display !== 'none';
  });
  check('§4: Materials hidden from admin nav', !materialsVisible);
  check('§4: Announcements hidden from admin nav', !announceVisible);

  // §6: Classmates nav item + screen fully gone
  const classroomNavExists = await page.evaluate(() => !!document.querySelector('[data-id="classroom"]'));
  const classroomScreenExists = await page.evaluate(() => !!document.getElementById('screen-classroom'));
  check('§6: Classmates nav item removed', !classroomNavExists);
  check('§6: classroom screen removed', !classroomScreenExists);

  await browser.close();
  const failed = results.filter(r => !r.ok);
  console.log('\n' + results.length + ' checks, ' + failed.length + ' failed');
  process.exit(failed.length ? 1 : 0);
})();
