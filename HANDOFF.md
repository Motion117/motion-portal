# Motion Language Centre Portal — Project Handoff

Paste this whole document as your first message in the new Claude Code session. It gives full context on architecture, current state, critical rules, and where to pick up.

---

## What this project is

A student/teacher portal for "Motion", an English/IELTS language learning centre (based in Uzbekistan — vocab definitions are in Russian). Students log in to see schedules, homework, grades, attendance, a leaderboard, an AI essay/IELTS checker, vocab flashcards, a grammar trainer, and course chat. Teachers get a dashboard to manage classes, review submitted essays, post announcements, and message students.

**Owner's skill level:** Beginner — recently moved from VS Code to Cursor, still learning Claude Code. Always show diffs before applying changes, explain in plain language (no unexplained jargon), and ask before installing new npm packages, MCP servers, or skills.

---

## Architecture — three separate services

```
┌─────────────────────┐      ┌──────────────────────────┐      ┌─────────────────┐
│  GitHub Pages        │      │  Render (Node/Express)   │      │  Supabase        │
│  motion-portal repo  │─────▶│  motion-essay-api repo   │─────▶│  Postgres + Auth │
│  index.html (static) │ HTTP │  server.js                │ REST │  project:        │
│                       │      │                           │      │  ubiafzrwrbnytbptnrcf │
└─────────────────────┘      └──────────────────────────┘      └─────────────────┘
        ▲                                                              ▲
        └──────────────────────── direct client calls ─────────────────┘
           (Supabase JS SDK, using the public anon key — safe by design)
```

| Piece | Repo | URL | Notes |
|---|---|---|---|
| Frontend | `Motion117/motion-portal` (public) | https://motion117.github.io/motion-portal/ | Single file: `index.html`. No build step — deployed by uploading the raw file via GitHub's web UI (drag-and-drop or the pencil/edit icon on the file page). |
| Backend | `Motion117/motion-essay-api` (private) | https://motion-essay-api.onrender.com | Node/Express on Render free tier. Auto-deploys on push to `main`. Proxies OpenAI calls so the API key never touches the browser. |
| Database/Auth | Supabase project `ubiafzrwrbnytbptnrcf` | https://ubiafzrwrbnytbptnrcf.supabase.co | Postgres + Auth. Frontend talks to it directly using the public anon key for reads/writes governed by Row Level Security (RLS); backend uses a service-role key (server-side only) for privileged writes. |

**Local working copies on this machine:**
- Frontend source: `C:\Users\hp\Downloads\motion\index.html` (this is NOT a git repo — deploy by manual upload)
- Backend source: `C:\Users\hp\Documents\GitHub\motion-essay-api\` (this IS a git repo, pushes via GitHub Desktop)

---

## CRITICAL — security rules (never break these)

1. **Never call the OpenAI or Anthropic API directly from `index.html` / client-side JS.** All AI requests must go through `ESSAY_ENDPOINT` (`https://motion-essay-api.onrender.com`). A secret API key in client-side JS is visible to anyone via "View Source" — that's a real security hole.
2. **The `.env` file in `motion-essay-api` (holds the real `OPENAI_API_KEY` and `SUPABASE_SERVICE_KEY`) must NEVER be committed or pushed to GitHub.** It's already in `.gitignore`. Also never push `server.log`, `server.err`, `.claude/`, or `node_modules/`.
3. **Demo/local login must always keep working**, even if Supabase is down or misconfigured. Demo accounts: `student/student123`, `teacher/teacher2026`. These generate a fake local `uid` (format `local-xxxxx`, persisted in `localStorage` under the `motion_portal_v8` store's `localUid` key) and do **not** create a real Supabase auth session. Any new feature that assumes `session.uid` implies a real authenticated Supabase user will silently break for demo accounts, because Supabase RLS policies reject writes from non-authenticated requests.
4. **Always use `escHtml()`** when rendering any user-supplied text into the DOM (XSS prevention). This is already used consistently — keep doing it in new code.
5. **This is intentionally one big HTML file.** Don't split it into multiple files/modules unless explicitly asked — the owner wants to review changes as a single diff while they're still learning.
6. The Supabase **anon key** embedded in `index.html` (line ~2777) is meant to be public — it's protected by Row Level Security policies on the Supabase side, not secrecy. This is normal and fine, don't try to "fix" it by hiding it.

---

## Database schema (tables actually in use)

Two *different* tables are used for what looks like similar data — don't conflate them:

- **`essay_history`** — written directly from the browser via the Supabase JS SDK (`_sb.from('essay_history').insert(...)`, see `saveEssayToHistory()` around line 4583). Powers the "Save to History" button and the student's own essay-history view. Works for demo users because it just needs `localUid`, not a real Supabase auth session (RLS policy must allow this — check policies if this ever breaks again).
- **`public_essay_history`** — written server-side, from `motion-essay-api`'s `/api/save-essay` route, using the Supabase **service role key** (bypasses RLS). Powers the "Submit to Teacher" button and the teacher dashboard's essay review list (`_sb.from('public_essay_history').select(...)` around line 4432).

Other tables referenced: `announcements`, `lessons`, `vocabulary`, `grammar_drills`, `messages`.

---

## Backend API surface (`motion-essay-api/server.js`)

- `POST /api/check-essay` — runs LanguageTool + a per-sentence GPT-4o pass (parallelized), merges/dedupes overlapping errors, returns a computed score.
- `POST /api/rewrite-essay` — full essay rewrite with a change list.
- `POST /api/band-score` — IELTS band scoring (TA/CC/LR/GRA), supports vision input for Task 1 chart images.
- `POST /api/vocab-generate` — AI-generated vocab entries (fill single word, or suggest new word for a lesson topic).
- `POST /api/chat` — the in-app AI study assistant.
- `POST /api/lesson-enhance` — auto-generates an emoji + description for a new lesson.
- `POST /api/grammar-drills` — AI-generated MCQ grammar questions.
- `POST /api/save-essay` — writes to `public_essay_history` (used by "Submit to Teacher").
- `GET /health`, `GET /debug/openai` — diagnostics.

Env vars the backend needs (set in Render dashboard, and in a local `.env` for dev — never commit this file): `OPENAI_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `ALLOWED_ORIGINS` (comma-separated CORS allowlist), `PORT` (Render sets this automatically).

---

## Recently fixed — already deployed, don't re-fix

As of the last push (`823b0d0` on `motion-essay-api`, and the latest upload to `motion-portal`), these are confirmed **live in production** — I verified both directly against GitHub, not just local files:

1. **PGRST125 "Invalid path specified" on Submit to Teacher** — `SUPABASE_URL` sometimes had a trailing slash, which combined with the hardcoded `/rest/v1/` prefix produced a double slash Supabase's REST API rejected. Fixed in `supabaseInsert()` (`server.js` line 63) by stripping trailing slashes: `(process.env.SUPABASE_URL || '').trim().replace(/\/+$/, '')`.
2. **"Please log in to save essays" shown to already-logged-in demo users** — `saveEssayToHistory()` requires `session.uid`, but demo/local logins never set one. Fixed in `doLogin()`'s local-fallback branches: generate and persist a stable `localUid` (`local-<timestamp>-<random>`) the first time a demo user logs in, and attach it to the session.
3. **"Download Detailed Academic Report" button visually higher than its neighbors** — `.hw-btn` has a `margin-top:10px` that doesn't apply evenly. Fixed by adding `margin-top:0` inline on `#portal-save-btn` and `#portal-submit-btn`.
4. Also fixed earlier: essay save errors were being silently swallowed server-side — now surfaced properly (`e7ef727`).

An older 18-bug audit was done against a stale local snapshot (`motion_portal_v8 (2).html`, 192KB) that is **not** the deployed file — the real `index.html` (420KB+) had already organically fixed all 18 of those issues through iteration. That snapshot file is dead weight; ignore it (don't waste time "fixing" it, it isn't deployed anywhere).

---

## Deployment mechanics (how to actually ship a change)

**Backend (`motion-essay-api`):**
```
cd C:\Users\hp\Documents\GitHub\motion-essay-api
git add -A
git commit -m "..."
git push
```
Render auto-deploys on push to `main` (usually live within ~2 minutes). If `git push` fails with `fatal: User cancelled dialog` / `could not read Username` — that's Windows Credential Manager trying to open a GUI auth dialog that can't render in a non-interactive shell. Fall back to **GitHub Desktop** (already signed in): open the repo, click "Push origin".

**Frontend (`motion-portal`):** Not a git repo locally — there is no `git push` path. Deploy by uploading `index.html` directly through the GitHub web UI: go to https://github.com/Motion117/motion-portal, click `index.html`, click the pencil (edit) icon, paste/replace content, commit to `main`. GitHub Pages redeploys automatically within about a minute.

If you'd rather set up a proper git-based workflow for the frontend (clone `motion-portal` locally, get real diffs/history instead of copy-pasting through a browser textarea), that's a reasonable improvement to propose to the owner — but ask first, since it changes their workflow.

---

## Ideas for "becoming even better" (not yet done — proposals, not commitments)

Use judgment and confirm with the owner before diving into anything big; they're a beginner and want to stay in the loop. Some directions worth considering:

- **Turn `motion-portal` into a real local git repo** cloned to disk, so frontend changes get proper diffs/history/rollback instead of manual browser uploads.
- **Add automated tests** for the backend's essay-checking pipeline (it's pure logic-heavy: offset resolution, error merging/dedup, sentence splitting) — currently untested.
- **Rate-limit / cost-guard the AI endpoints** more tightly — `/api/check-essay` fires one OpenAI call *per sentence* in parallel, which could get expensive on long essays or if abused; consider a stricter per-user daily cap enforced server-side, not just the existing 20-req/min IP rate limit.
- **Review Supabase RLS policies** — confirm they correctly cover both real Supabase-authenticated users and the demo `local-*` uid pattern, especially for tables newer features might touch, so silent RLS rejections (Supabase doesn't throw on RLS failure, it just returns `{data: null, error: ...}`) don't produce more "invisible" bugs like the Save-to-History one.
- **Consider a real PWA setup** (manifest + service worker) since remnants of that intent existed in earlier versions and got stripped — only worth it if offline support or installability is actually wanted.

---

## Where to start

1. Read this document fully before touching code.
2. Open `C:\Users\hp\Downloads\motion\index.html` and `C:\Users\hp\Documents\GitHub\motion-essay-api\server.js` to get current with the real code (this handoff describes architecture and state, not line-by-line contents — those will drift).
3. Ask the owner what they want to work on next — there's no known open bug right now; everything reported so far has been fixed and verified live.
