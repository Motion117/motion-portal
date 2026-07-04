-- ============================================================================
-- MOTION PORTAL — FREEZE / UNFREEZE ACCOUNTS (addendum)
-- ============================================================================
-- REVIEW, THEN RUN ONCE in Supabase Dashboard → SQL Editor.
-- Prerequisite: admin_role.sql must already be applied (this reuses its
-- _assert_admin() helper and admin_audit_log table).
--
-- Held back for a human look for the same reason as admin_role.sql: it can
-- block a user's login. It grants NO new powers beyond what the admin already
-- has, uses the exact same SECURITY DEFINER pattern, needs no service-role key,
-- and logs every action.
--
-- WHAT THIS INSTALLS (for review):
--   1. admin_set_account_frozen(p_user_id uuid, p_frozen boolean)
--        · verifies caller is admin (_assert_admin), refuses to touch admin
--          accounts, refuses self.
--        · FREEZE: sets auth.users.banned_until far in the future (blocks new
--          logins + token refreshes) AND deletes that user's existing sessions
--          and refresh tokens, so an already-logged-in session is cut off at
--          its very next token refresh instead of lingering.
--        · UNFREEZE: clears banned_until (login works again immediately).
--        · writes 'freeze_user' / 'unfreeze_user' to admin_audit_log.
--        · NO data is touched — homework, grades, essays, chat, lessons the
--          account created all stay exactly as they are. Freezing a teacher
--          only blocks that teacher's login; their content stays visible to
--          students (hiding content would be a separate toggle — not built
--          here; ask if you want it).
--   2. A `create or replace` of admin_list_users() that ALSO returns an
--        `is_frozen boolean` column, so the admin roster can show status.
--        Identical to the version in admin_role.sql except for that one added
--        column — safe to re-run.
-- ============================================================================

-- ─── 1. Freeze / unfreeze ────────────────────────────────────────────────────
create or replace function public.admin_set_account_frozen(p_user_id uuid, p_frozen boolean)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_target auth.users%rowtype;
begin
  v_actor := public._assert_admin();
  select * into v_target from auth.users u where u.id = p_user_id;
  if not found then raise exception 'user not found'; end if;
  if p_user_id = v_actor then raise exception 'you cannot freeze your own account'; end if;
  if coalesce(v_target.raw_user_meta_data->>'role','') = 'admin' then
    raise exception 'admin accounts cannot be frozen';
  end if;

  if p_frozen then
    update auth.users set banned_until = now() + interval '100 years', updated_at = now()
      where auth.users.id = p_user_id;
    -- Cut off any session that is already open so the lockout is prompt, not
    -- delayed until the current access token happens to expire. Deleting the
    -- refresh tokens + sessions means the next refresh (or any 401) ends it.
    delete from auth.refresh_tokens where user_id = p_user_id::text;
    delete from auth.sessions where user_id = p_user_id;
  else
    update auth.users set banned_until = null, updated_at = now()
      where auth.users.id = p_user_id;
  end if;

  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email',
          case when p_frozen then 'freeze_user' else 'unfreeze_user' end,
          p_user_id, v_target.email,
          jsonb_build_object('name', v_target.raw_user_meta_data->>'name',
                             'role', v_target.raw_user_meta_data->>'role'));
end $$;

revoke execute on function public.admin_set_account_frozen(uuid, boolean) from public, anon;
grant execute on function public.admin_set_account_frozen(uuid, boolean) to authenticated;

-- ─── 2. admin_list_users() + is_frozen column ───────────────────────────────
create or replace function public.admin_list_users()
returns table(id uuid, email text, role text, full_name text, group_name text,
              created_at timestamptz, last_sign_in_at timestamptz, is_frozen boolean)
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  perform public._assert_admin();
  return query
    select u.id, u.email::text,
           coalesce(u.raw_user_meta_data->>'role','student'),
           coalesce(u.raw_user_meta_data->>'name', p.full_name, ''),
           coalesce(u.raw_user_meta_data->>'group', p.group_name, ''),
           u.created_at, u.last_sign_in_at,
           (u.banned_until is not null and u.banned_until > now()) as is_frozen
    from auth.users u
    left join public.profiles p on p.id = u.id
    order by u.created_at;
end $$;

revoke execute on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;
