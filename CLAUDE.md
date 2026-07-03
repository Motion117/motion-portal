# Motion — Learning Centre Student Portal

## What this is
A single-file HTML/CSS/JS web app (`index.html`) for a language learning
centre. Students and teachers log in to see schedules, homework, grades,
attendance, a leaderboard, an AI essay/IELTS checker, and course chat.

Backend: Supabase (auth + database).
AI essay checking: proxied through a separate backend on Render
(`motion-essay-api`, in its own repo/folder — NOT part of this project).

## Critical rules — do not break these

1. **Never call Anthropic/OpenAI APIs directly from this file.**
   All AI requests must go through `ESSAY_ENDPOINT`
   (`https://motion-essay-api.onrender.com`). Putting a secret API key in
   client-side JS is a real security hole — anyone can view page source
   and steal it.

2. **Demo/local login must always keep working**, even if Supabase is
   down or misconfigured. Demo accounts: `student/student123`,
   `teacher/teacher2026`. These generate a fake local `uid` and do NOT
   create a real Supabase auth session — keep this in mind before adding
   any feature that assumes `session.uid` implies a real authenticated
   Supabase user (e.g. Row Level Security policies will reject writes
   from demo accounts unless designed around this).

3. **Always use `escHtml()`** when rendering any user-supplied text into
   the DOM, to avoid XSS.

4. **This is one big file on purpose (for now).** Don't split it into
   multiple files unless explicitly asked — I'm still learning, keep
   changes contained and easy for me to review as a single diff.

## Known architecture

- `_sb` — the Supabase client instance. Check for `_sb === null` before
  any Supabase call; it can fail to initialize silently (watch console
  for `[Motion] Supabase init failed`).
- `session` — current logged-in user, either real (Supabase auth) or
  demo (`local-xxxx` uid).
- `submitEssayToTeacher()` — sends essay to teacher, POSTs to
  `ESSAY_ENDPOINT + '/api/save-essay'` on the Render backend.
- `saveEssayHistory()` — writes a row to `essay_history` in Supabase
  directly from the client. Always check `{data, error}` from any
  `.insert()`/`.update()` call — Supabase does not throw on RLS
  rejection, it fails silently unless you check the returned error.

## My skill level — please account for this

I'm new to coding tools (recently moved from VS Code to Cursor, still
learning Claude Code itself). When making changes:

- Always show me the diff before applying it.
- Explain what you changed and why, in plain language, no jargon.
- For anything touching auth, payments, or the AI proxy: extra caution,
  explain the risk before proceeding.
- Don't install new npm packages, MCP servers, or skills without asking
  me first and explaining what it's for.

## Related project

The AI backend server lives in a **separate** repo/folder:
`motion-essay-api` (Node/Express, deployed on Render, connects to the
same Supabase project). If a bug could be on either side, ask which
folder is currently open before assuming.
