const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const results = [];
  const check = (name, cond, extra) => { results.push({ name, ok: !!cond, extra }); console.log((cond ? 'PASS' : 'FAIL') + ' - ' + name + (extra ? ' :: ' + extra : '')); };

  // ── 1. Fresh incognito visit: should show landing, not login, not portal ──
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://localhost:8791/index.html');
    await page.waitForTimeout(2200); // splash + settle
    const landingOpen = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    const loginVisible = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    const bodyRole = await page.evaluate(() => document.body.getAttribute('data-role'));
    check('fresh visit: landing-page has .open', landingOpen);
    check('fresh visit: login overlay NOT shown', !loginVisible);
    check('fresh visit: body has no data-role', !bodyRole);
    check('fresh visit: no JS errors', errors.length === 0, errors.join(' | '));
    const lang = await page.evaluate(() => document.documentElement.lang);
    check('fresh visit: default language is ru', lang === 'ru', 'lang=' + lang);

    // Click Login button -> login overlay shows, landing stays underneath
    await page.click('#ld-login-link');
    await page.waitForTimeout(200);
    const loginVisible2 = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    check('after clicking Login: login overlay shown', loginVisible2);

    // Click back -> login hides, landing still open underneath
    await page.click('.login-back-btn');
    await page.waitForTimeout(200);
    const loginVisible3 = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    const landingStillOpen = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    check('after Back: login overlay hidden again', !loginVisible3);
    check('after Back: landing still open underneath', landingStillOpen);
    await ctx.close();
  }

  // ── 2. Log in as student, teacher, admin — each routes correctly ──
  const logins = [
    { user: 'student', pass: 'student123', role: 'student' },
    { user: 'teacher', pass: 'teacher2026', role: 'teacher' },
  ];
  for (const { user, pass, role } of logins) {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto('http://localhost:8791/index.html');
    await page.waitForTimeout(2200);
    await page.click('#ld-login-link');
    await page.waitForTimeout(150);
    await page.fill('#login-user', user);
    await page.fill('#login-pass', pass);
    await page.click('.login-btn.primary');
    await page.waitForTimeout(3000);
    const bodyRole = await page.evaluate(() => document.body.getAttribute('data-role'));
    const landingOpen = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    const loginVisible = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    check(`login as ${user}: role set to ${role}`, bodyRole === role, 'got=' + bodyRole);
    check(`login as ${user}: landing hidden`, !landingOpen);
    check(`login as ${user}: login overlay hidden`, !loginVisible);

    // Reload same context (persisted local session) -> should land straight in portal, no landing flash
    await page.goto('http://localhost:8791/index.html');
    await page.waitForTimeout(2200);
    const bodyRole2 = await page.evaluate(() => document.body.getAttribute('data-role'));
    const landingOpen2 = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    check(`reload with session (${user}): still role ${role}, no landing`, bodyRole2 === role && !landingOpen2, 'role=' + bodyRole2 + ' landingOpen=' + landingOpen2);

    // Logout -> should land back on landing page, not login form
    await page.evaluate(() => logout());
    await page.waitForTimeout(300);
    const landingOpen3 = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    const loginVisible2 = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    const bodyRole3 = await page.evaluate(() => document.body.getAttribute('data-role'));
    check(`logout from ${role}: lands on landing page`, landingOpen3);
    check(`logout from ${role}: login overlay NOT shown`, !loginVisible2);
    check(`logout from ${role}: body role cleared`, !bodyRole3);
    await ctx.close();
  }

  // ── 3. Mobile viewport ──
  {
    const ctx = await browser.newContext({ viewport: { width: 375, height: 812 } });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://localhost:8791/index.html');
    await page.waitForTimeout(2200);
    const landingOpen = await page.evaluate(() => document.getElementById('landing-page').classList.contains('open'));
    check('mobile (375px): landing shows', landingOpen);
    const overflowX = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 2);
    check('mobile (375px): no horizontal overflow', !overflowX, 'scrollWidth vs clientWidth mismatch=' + overflowX);
    // burger menu opens
    await page.click('.ld-burger');
    await page.waitForTimeout(150);
    const menuOpen = await page.evaluate(() => document.getElementById('ld-mainnav').classList.contains('open'));
    check('mobile: burger opens nav menu', menuOpen);
    // login link inside mobile menu works
    await page.click('#ld-mainnav .ld-login-btn.in-menu');
    await page.waitForTimeout(200);
    const loginVisible = await page.evaluate(() => getComputedStyle(document.getElementById('login-overlay')).display !== 'none');
    check('mobile: Login (in menu) opens login form', loginVisible);
    check('mobile: no JS errors', errors.length === 0, errors.join(' | '));
    await ctx.close();
  }

  await browser.close();
  const failed = results.filter(r => !r.ok);
  console.log('\n' + results.length + ' checks, ' + failed.length + ' failed');
  process.exit(failed.length ? 1 : 0);
})();
