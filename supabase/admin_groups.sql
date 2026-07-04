-- ============================================================================
-- MOTION PORTAL — GROUPS WITHIN LEVELS (addendum Part 2 §2)
-- ============================================================================
-- REVIEW, THEN RUN ONCE in Supabase Dashboard → SQL Editor.
-- Prerequisite: admin_role.sql must already be applied (reuses its
-- _assert_admin() helper and admin_audit_log table).
--
-- Held back for a human look for the same reason as admin_role.sql /
-- admin_freeze.sql: it changes how every group-facing screen looks up group
-- names and adds four new admin-only write paths. Every function below is
-- the same SECURITY DEFINER pattern already in use — it verifies the caller
-- is admin, refuses invalid input, and logs an audit row.
--
-- WHAT THIS INSTALLS (summary for review):
--   1. A new `groups` table: id, level (one of the 5 fixed CEFR levels —
--      same slugs already used by lessons/grammar_drills/dictation_sentences),
--      name, frozen, created_at. Readable by anyone (even logged-out visitors
--      picking a group on the signup form) — group names/levels are not
--      private data, same public-read treatment as lessons/vocabulary.
--   2. A seed insert: one real group per EXISTING flat group, carrying the
--      exact old name forward ('Beginner A1', 'Elementary A2', etc.). This
--      does NOT touch profiles/homework/schedule/announcements/messages/
--      essay_submissions at all — they keep matching by the same text they
--      always matched by, so no existing student's data moves or breaks.
--   3. Four admin-only RPCs: admin_create_group, admin_set_group_frozen,
--      admin_delete_group, admin_set_student_group.
--
-- ── IMPORTANT DESIGN TRADEOFF — READ BEFORE RUNNING ──────────────────────
-- Every existing group-bearing column (profiles.group_name, homework.group_name,
-- schedule.group_name, essay_submissions.group_name, announcements.target_group,
-- messages.target_group) is a plain TEXT column that matches by NAME, not by
-- an id/foreign key. Rewriting all six of those columns (and every query
-- against them) to use a group_id foreign key would be a far larger, riskier
-- migration than what this addendum describes ("groups within levels"), and
-- would touch nearly every screen in the app a second time.
--
-- Instead, this migration keeps NAME as the join key everywhere it already
-- is, and only adds the new `groups` table as the live source of truth for
-- WHICH names exist, under WHICH level, and whether they're frozen. The
-- practical consequence: group names must be unique ACROSS ALL LEVELS, not
-- just within one level — you can't have a "Morning" group under both
-- Beginner and Elementary at the same time. If that's ever a real need, say
-- so and this can be upgraded to a proper group_id foreign-key model later;
-- for now the admin "add group" screen enforces uniqueness and shows a clear
-- "that name is already taken" error, the same way username creation already
-- does elsewhere in this app.
-- ============================================================================

-- ─── 1. groups table ─────────────────────────────────────────────────────
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  level text not null check (level in ('beginner','elementary','pre-intermediate','pre-ielts','ielts')),
  name text not null,
  frozen boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index if not exists groups_name_unique on public.groups (lower(name));

alter table public.groups enable row level security;
drop policy if exists groups_select_all on public.groups;
create policy groups_select_all on public.groups for select to public using (true);
-- No insert/update/delete policy for any role — every write goes through the
-- SECURITY DEFINER functions below, which verify admin first. Safe to leave
-- RLS with no write policies at all: that means "nobody, via the table
-- directly," which is exactly what we want.

-- ─── 2. seed: one group per existing flat level/group, same name as today ──
insert into public.groups (level, name)
values
  ('beginner','Beginner A1'),
  ('elementary','Elementary A2'),
  ('pre-intermediate','Pre-Intermediate B1'),
  ('pre-ielts','Pre-IELTS B2'),
  ('ielts','IELTS Prep C1')
on conflict (lower(name)) do nothing;

-- ─── 3. Admin group management ──────────────────────────────────────────────
create or replace function public.admin_create_group(p_level text, p_name text)
returns public.groups
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_row public.groups;
begin
  v_actor := public._assert_admin();
  if p_level not in ('beginner','elementary','pre-intermediate','pre-ielts','ielts') then
    raise exception 'invalid level';
  end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'group name is required'; end if;
  if exists (select 1 from public.groups g where lower(g.name) = lower(trim(p_name))) then
    raise exception 'a group with this name already exists';
  end if;
  insert into public.groups(level, name) values (p_level, trim(p_name)) returning * into v_row;
  insert into public.admin_audit_log(actor_id, actor_email, action, details)
  values (v_actor, auth.jwt()->>'email', 'create_group', jsonb_build_object('level',p_level,'name',v_row.name));
  return v_row;
end $$;

revoke execute on function public.admin_create_group(text,text) from public, anon;
grant execute on function public.admin_create_group(text,text) to authenticated;

create or replace function public.admin_set_group_frozen(p_group_id uuid, p_frozen boolean)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_row public.groups;
begin
  v_actor := public._assert_admin();
  select * into v_row from public.groups where id = p_group_id;
  if not found then raise exception 'group not found'; end if;
  update public.groups set frozen = p_frozen where id = p_group_id;
  insert into public.admin_audit_log(actor_id, actor_email, action, details)
  values (v_actor, auth.jwt()->>'email',
          case when p_frozen then 'freeze_group' else 'unfreeze_group' end,
          jsonb_build_object('group_id', p_group_id, 'name', v_row.name));
end $$;

revoke execute on function public.admin_set_group_frozen(uuid,boolean) from public, anon;
grant execute on function public.admin_set_group_frozen(uuid,boolean) to authenticated;

-- Deleting a group requires reassigning its members first — a group whose
-- name is still referenced by any profile is refused, so we never end up
-- with students/teachers pointing at a group the pickers no longer know
-- about. (Their group_name value would keep working for schedule/homework/
-- chat/etc, since those still match by name — but they'd become invisible
-- to every screen that lists groups from this table, which is confusing and
-- entirely avoidable by requiring reassignment first.)
create or replace function public.admin_delete_group(p_group_id uuid)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_row public.groups; v_assigned int;
begin
  v_actor := public._assert_admin();
  select * into v_row from public.groups where id = p_group_id;
  if not found then raise exception 'group not found'; end if;
  select count(*) into v_assigned from public.profiles where group_name = v_row.name;
  if v_assigned > 0 then
    raise exception 'reassign % account(s) out of this group before deleting it', v_assigned;
  end if;
  delete from public.groups where id = p_group_id;
  insert into public.admin_audit_log(actor_id, actor_email, action, details)
  values (v_actor, auth.jwt()->>'email', 'delete_group', jsonb_build_object('group_id', p_group_id, 'name', v_row.name));
end $$;

revoke execute on function public.admin_delete_group(uuid) from public, anon;
grant execute on function public.admin_delete_group(uuid) to authenticated;

-- Assign an EXISTING student/teacher to a (possibly different) group. This is
-- new capability — today the app can only set a group at account-creation
-- time. Writes through auth.users.raw_user_meta_data (same as every other
-- admin credential change) so the existing on_auth_user_metadata_updated
-- trigger syncs public.profiles.group_name automatically — no dual write.
create or replace function public.admin_set_student_group(p_user_id uuid, p_group_name text)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_target auth.users%rowtype;
begin
  v_actor := public._assert_admin();
  select * into v_target from auth.users u where u.id = p_user_id;
  if not found then raise exception 'user not found'; end if;
  if coalesce(v_target.raw_user_meta_data->>'role','') = 'admin' then
    raise exception 'admin accounts do not belong to a group';
  end if;
  if not exists (select 1 from public.groups where name = p_group_name) then
    raise exception 'unknown group';
  end if;
  update auth.users set raw_user_meta_data = raw_user_meta_data || jsonb_build_object('group', p_group_name), updated_at = now()
    where id = p_user_id;
  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email', 'set_student_group', p_user_id, v_target.email,
          jsonb_build_object('group', p_group_name));
end $$;

revoke execute on function public.admin_set_student_group(uuid,text) from public, anon;
grant execute on function public.admin_set_student_group(uuid,text) to authenticated;
