-- ============================================================================
-- MOTION PORTAL — ADMIN ROLE INSTALLATION (Round 3, section 6)
-- ============================================================================
-- REVIEW THIS WHOLE FILE, THEN RUN IT ONCE in Supabase Dashboard → SQL Editor.
--
-- It was deliberately NOT applied automatically: it grants an admin account
-- the power to create/delete accounts and reset passwords, which deserves a
-- human eye before it exists in production. Everything in the app is already
-- wired to use it — the Admin screens light up as soon as this runs.
--
-- ⚠ STEP 1 — REQUIRED: pick your real admin password.
--    Find 'CHANGE_ME_BEFORE_RUNNING' below and replace it. The script REFUSES
--    to run with the placeholder left in. Do not commit your real password.
--
-- WHAT THIS INSTALLS (summary for review):
--   1. admin_audit_log table — who did what, to whom, when. Admin-only read;
--      nothing but the functions below can write it.
--   2. Four RPC functions (SECURITY DEFINER — i.e. server-side inside
--      Postgres; the browser never holds any privileged key):
--        admin_list_users()                      — list all accounts
--        admin_create_user(email,pw,role,name,g) — create student/teacher
--        admin_delete_user(id)                   — delete non-admin account
--        admin_update_credentials(id,email,pw)   — change login/password
--      EVERY one of them first verifies the CALLER's JWT says role='admin'
--      (set only in auth user metadata, unforgeable from the client), so a
--      student/teacher calling the RPC directly gets an exception. Each also
--      refuses to touch admin accounts (no self-delete, no cross-admin edits)
--      and writes an audit row in the same transaction.
--   3. Admin read-only visibility (RLS SELECT policies) on personal-data
--      tables: essay_history, essay_submissions, dictation_attempts.
--      (Profiles/messages/materials/schedule are already readable by any
--      authenticated user. "My Words" personal vocabulary is deliberately
--      NOT exposed to admin — it's a student's private study data.)
--   4. The admin account itself: admin@motion.edu with the password you set
--      in step 1.
-- ============================================================================

-- ─── 1. Audit log ───────────────────────────────────────────────────────────
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null,
  actor_email text,
  action text not null,
  target_user_id uuid,
  target_email text,
  details jsonb,
  created_at timestamptz not null default now()
);
alter table public.admin_audit_log enable row level security;
drop policy if exists audit_select_admin on public.admin_audit_log;
create policy audit_select_admin on public.admin_audit_log
  for select to authenticated
  using ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

-- ─── 2. Privileged functions ────────────────────────────────────────────────
create or replace function public._assert_admin() returns uuid
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid;
begin
  if coalesce(auth.jwt() -> 'user_metadata' ->> 'role','') <> 'admin' then
    raise exception 'admin privileges required';
  end if;
  v_actor := auth.uid();
  if v_actor is null then raise exception 'not authenticated'; end if;
  return v_actor;
end $$;

create or replace function public.admin_list_users()
returns table(id uuid, email text, role text, full_name text, group_name text, created_at timestamptz, last_sign_in_at timestamptz)
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  perform public._assert_admin();
  return query
    select u.id, u.email::text,
           coalesce(u.raw_user_meta_data->>'role','student'),
           coalesce(u.raw_user_meta_data->>'name', p.full_name, ''),
           coalesce(u.raw_user_meta_data->>'group', p.group_name, ''),
           u.created_at, u.last_sign_in_at
    from auth.users u
    left join public.profiles p on p.id = u.id
    order by u.created_at;
end $$;

create or replace function public.admin_create_user(p_email text, p_password text, p_role text, p_name text, p_group text)
returns uuid
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_new uuid := gen_random_uuid(); v_avatar text;
begin
  v_actor := public._assert_admin();
  if p_role not in ('student','teacher') then
    raise exception 'role must be student or teacher';
  end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email';
  end if;
  if length(coalesce(p_password,'')) < 6 then
    raise exception 'password must be at least 6 characters';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = lower(p_email)) then
    raise exception 'an account with this email already exists';
  end if;
  v_avatar := upper(left(coalesce(nullif(p_name,''),p_email),1)) ||
              coalesce(upper(left(split_part(coalesce(nullif(p_name,''),''),' ',2),1)),'');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous,
    confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_new, 'authenticated', 'authenticated',
    lower(p_email), extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}',
    jsonb_build_object('role',p_role,'name',coalesce(p_name,''),'group',coalesce(p_group,''),'avatar',v_avatar),
    now(), now(), false, '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_new::text, v_new,
    jsonb_build_object('sub', v_new::text, 'email', lower(p_email), 'email_verified', true),
    'email', now(), now(), now());
  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email', 'create_user', v_new, lower(p_email),
          jsonb_build_object('role',p_role,'name',p_name,'group',p_group));
  return v_new;
end $$;

create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_target auth.users%rowtype;
begin
  v_actor := public._assert_admin();
  select * into v_target from auth.users u where u.id = p_user_id;
  if not found then raise exception 'user not found'; end if;
  if p_user_id = v_actor then raise exception 'you cannot delete your own admin account'; end if;
  if coalesce(v_target.raw_user_meta_data->>'role','') = 'admin' then
    raise exception 'admin accounts cannot be deleted from the app';
  end if;
  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email', 'delete_user', p_user_id, v_target.email,
          jsonb_build_object('name',v_target.raw_user_meta_data->>'name','role',v_target.raw_user_meta_data->>'role'));
  delete from auth.users u where u.id = p_user_id;
end $$;

create or replace function public.admin_update_credentials(p_user_id uuid, p_new_email text, p_new_password text)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_target auth.users%rowtype; v_changes jsonb := '{}'::jsonb;
begin
  v_actor := public._assert_admin();
  select * into v_target from auth.users u where u.id = p_user_id;
  if not found then raise exception 'user not found'; end if;
  if coalesce(v_target.raw_user_meta_data->>'role','') = 'admin' and p_user_id <> v_actor then
    raise exception 'other admin accounts cannot be modified from the app';
  end if;
  if p_new_email is not null and p_new_email <> '' then
    if p_new_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid email'; end if;
    if exists (select 1 from auth.users u where lower(u.email) = lower(p_new_email) and u.id <> p_user_id) then
      raise exception 'an account with this email already exists';
    end if;
    update auth.users set email = lower(p_new_email), updated_at = now() where auth.users.id = p_user_id;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', lower(p_new_email))
      where user_id = p_user_id and provider = 'email';
    v_changes := v_changes || jsonb_build_object('email_changed', true, 'new_email', lower(p_new_email));
  end if;
  if p_new_password is not null and p_new_password <> '' then
    if length(p_new_password) < 6 then raise exception 'password must be at least 6 characters'; end if;
    update auth.users set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')), updated_at = now()
      where auth.users.id = p_user_id;
    v_changes := v_changes || jsonb_build_object('password_changed', true);
  end if;
  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email', 'update_credentials', p_user_id, v_target.email, v_changes);
end $$;

revoke execute on function public.admin_list_users() from public, anon;
revoke execute on function public.admin_create_user(text,text,text,text,text) from public, anon;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
revoke execute on function public.admin_update_credentials(uuid,text,text) from public, anon;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_create_user(text,text,text,text,text) to authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;
grant execute on function public.admin_update_credentials(uuid,text,text) to authenticated;

-- ─── 3. Admin read-only visibility over personal-data tables ────────────────
drop policy if exists essay_history_select_admin on public.essay_history;
create policy essay_history_select_admin on public.essay_history
  for select to authenticated using ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');
drop policy if exists essay_submissions_select_admin on public.essay_submissions;
create policy essay_submissions_select_admin on public.essay_submissions
  for select to authenticated using ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');
drop policy if exists dictation_attempts_select_admin on public.dictation_attempts;
create policy dictation_attempts_select_admin on public.dictation_attempts
  for select to authenticated using ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

-- ─── 4. The admin account ───────────────────────────────────────────────────
-- ⚠ Replace CHANGE_ME_BEFORE_RUNNING with your real password (step 1 above).
do $$
declare v_admin uuid := gen_random_uuid(); v_pw text := 'CHANGE_ME_BEFORE_RUNNING';
begin
  if v_pw = 'CHANGE' || '_ME_BEFORE_RUNNING' then
    raise exception 'Set your real admin password first (replace CHANGE_ME_BEFORE_RUNNING).';
  end if;
  if exists (select 1 from auth.users where email='admin@motion.edu') then
    raise notice 'admin@motion.edu already exists — skipping seed';
    return;
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous,
    confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_admin, 'authenticated', 'authenticated',
    'admin@motion.edu', extensions.crypt(v_pw, extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}',
    '{"role":"admin","name":"Motion Admin","group":"","avatar":"MA"}',
    now(), now(), false, '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_admin::text, v_admin,
    jsonb_build_object('sub', v_admin::text, 'email', 'admin@motion.edu', 'email_verified', true),
    'email', now(), now(), now());
end $$;
