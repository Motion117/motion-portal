// Round 3 regression harness — run before declaring any future round done:
//   node qa/serve.js 8788   (in one terminal, or started by the runner)
//   node qa/regression.js
//
// Exists because the duplicate-student and role-flash bugs regressed after
// Round 2 without anything catching them. This script asserts the invariants
// that would have caught both immediately:
//   1. Logging in/out repeatedly (same tab AND fresh contexts) NEVER changes
//      the total number of profiles — demo login must reuse fixed identities.
//   2. The rendered role always matches the account that just logged in, with
//      no wrong-role flash while the session settles.
//   3. No duplicate demo-name profiles exist in the database.
//
// IMPORTANT for future test authors: this harness logs in through the real UI
// but NEVER creates identities — demo accounts are fixed real users
// (student@motion.edu / teacher@motion.edu). If a future test needs a session,
// reuse one of these; do not add any signUp/anonymous path to tests.

const { chromium } = require('playwright');

const BASE = 'http://localhost:' + (Number(process.env.QA_PORT) || 8788);
const SUPABASE_URL = 'https://ubiafzrwrbnytbptnrcf.supabase.co';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InViaWFmenJ3cmJueXRicHRucmNmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI3NTEwMjcsImV4cCI6MjA5ODMyNzAyN30.ghk6upoSv4KdpkkCyQMLB0OsaVy2nLiKu0C9XWl2zWY'; // public anon key (safe to commit)
const ROLES = {
  student: { user: 'student', pass: 'student123' },
  teacher: { user: 'teacher', pass: 'teacher2026' },
};

async function apiToken() {
  const r = await fetch(SUPABASE_URL + '/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'teacher@motion.edu', password: 'teacher2026' }),
  });
  return (await r.json()).access_token;
}
async function countProfiles(token) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/profiles?select=id', {
    headers: { apikey: ANON_KEY, Authorization: 'Bearer ' + token, Prefer: 'count=exact', Range: '0-0' },
  });
  return Number((r.headers.get('content-range') || '/0').split('/')[1]);
}
async function demoDuplicates(token) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/profiles?select=full_name', {
    headers: { apikey: ANON_KEY, Authorization: 'Bearer ' + token },
  });
  const names = (await r.json()).map(p => p.full_name);
  const counts = {};
  for (const n of names) counts[n] = (counts[n] || 0) + 1;
  return Object.entries(counts).filter(([, c]) => c > 1);
}

async function login(page, role) {
  // Since the landing-page addendum, the login overlay is no longer shown
  // by default (the marketing landing page is) — open it first if needed.
  const overlayOpen = await page.evaluate(() => {
    const o = document.getElementById('login-overlay');
    return o && getComputedStyle(o).display !== 'none';
  });
  if (!overlayOpen) {
    await page.click('#ld-login-link');
    await page.waitForTimeout(150);
  }
  await page.fill('#login-user', ROLES[role].user);
  await page.fill('#login-pass', ROLES[role].pass);
  await page.click('.login-btn.primary');
  // The invariant that matters is the VISIBLE one: from the instant the login
  // overlay is dismissed, body[data-role] must already be the correct role and
  // must never change afterwards. (Stale attribute values while the overlay
  // still covers the screen are not user-visible and not a flash.)
  const seen = [];
  for (let i = 0; i < 40; i++) {
    const { r, overlayGone } = await page.evaluate(() => ({
      r: document.body.getAttribute('data-role'),
      overlayGone: (() => { const o = document.getElementById('login-overlay'); return !o || o.style.display === 'none'; })(),
    }));
    if (overlayGone && seen[seen.length - 1] !== r) seen.push(r);
    if (overlayGone && r === role && seen.length === 1) break;
    await page.waitForTimeout(150);
  }
  const wrong = role === 'student' ? 'teacher' : 'student';
  const flashed = seen.includes(wrong) || seen.length > 1;
  const finalRole = seen[seen.length - 1];
  return { ok: finalRole === role && !flashed, seen };
}
async function logout(page) {
  await page.evaluate(() => logout());
  await page.waitForTimeout(600);
}

(async () => {
  const failures = [];
  const token = await apiToken();
  if (!token) { console.error('FATAL: could not authenticate QA session'); process.exit(1); }
  const before = await countProfiles(token);
  console.log('profiles before stress test:', before);

  const browser = await chromium.launch();

  // Phase 1: 14 alternating logins in ONE tab, no reload (the Round 2/3 spec test)
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(BASE + '/index.html');
    await page.waitForTimeout(800);
    for (let i = 0; i < 14; i++) {
      const role = i % 2 === 0 ? 'teacher' : 'student';
      const res = await login(page, role);
      if (!res.ok) failures.push(`same-tab login #${i + 1} (${role}): role sequence ${JSON.stringify(res.seen)}`);
      await logout(page);
    }
    await ctx.close();
  }

  // Phase 2: 8 logins from FRESH contexts (cleared storage — the case that
  // regenerated duplicates under the old anonymous mechanism)
  for (let i = 0; i < 8; i++) {
    const role = i % 2 === 0 ? 'student' : 'teacher';
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(BASE + '/index.html');
    await page.waitForTimeout(800);
    const res = await login(page, role);
    if (!res.ok) failures.push(`fresh-context login #${i + 1} (${role}): role sequence ${JSON.stringify(res.seen)}`);
    await ctx.close();
  }

  await browser.close();

  const after = await countProfiles(token);
  console.log('profiles after stress test:', after);
  if (after !== before) failures.push(`PROFILE COUNT CHANGED: ${before} -> ${after} (identity minted during login!)`);

  const dupes = await demoDuplicates(token);
  if (dupes.length) failures.push('DUPLICATE PROFILES: ' + JSON.stringify(dupes));

  if (failures.length) {
    console.error('\nREGRESSION FAILURES:');
    failures.forEach(f => console.error(' - ' + f));
    process.exit(1);
  }
  console.log('\nALL REGRESSION CHECKS PASSED (22 logins, count stable at ' + after + ', no role flash, no duplicates)');
})().catch(e => { console.error('FATAL:', e); process.exit(1); });
