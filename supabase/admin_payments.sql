-- ============================================================================
-- MOTION PORTAL — PAYMENTS RECORD-KEEPING (addendum Part 2 §5)
-- ============================================================================
-- REVIEW, THEN RUN ONCE in Supabase Dashboard → SQL Editor.
-- Prerequisite: admin_role.sql must already be applied (reuses _assert_admin()
-- and admin_audit_log).
--
-- This is SIMPLE RECORD-KEEPING, not a payment processor. It never collects,
-- stores, or transmits a real card number, CVV, or any other card data — it
-- only lets admin type in "student X paid Y amount for month Z" after money
-- has already changed hands some other way (cash, Click/Payme transfer,
-- bank, etc.), same as a paper ledger. There is no payment-gateway
-- integration here at all.
--
-- WHAT THIS INSTALLS (summary for review):
--   1. payment_settings — a single-row table holding the current monthly
--      rate (defaults to 600,000 UZS, but admin can change it any time —
--      never hardcoded in the app).
--   2. payments — one row per student per month: amount, period (YYYY-MM),
--      when it was recorded paid, status, who recorded it, optional notes.
--   3. Four admin-only RPCs: admin_get_payment_settings, admin_set_monthly_rate,
--      admin_record_payment, admin_list_payment_status.
-- ============================================================================

-- ─── 1. payment_settings (singleton row) ────────────────────────────────────
create table if not exists public.payment_settings (
  id boolean primary key default true,
  monthly_rate numeric not null default 600000,
  updated_at timestamptz not null default now(),
  constraint payment_settings_singleton check (id)
);
insert into public.payment_settings (id, monthly_rate) values (true, 600000) on conflict (id) do nothing;

alter table public.payment_settings enable row level security;
-- No select/insert/update policy for any role — read/write only via the
-- SECURITY DEFINER functions below, which verify admin first.

-- ─── 2. payments ─────────────────────────────────────────────────────────────
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  amount numeric not null check (amount >= 0),
  period text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'), -- 'YYYY-MM'
  paid_at timestamptz not null default now(),
  status text not null default 'paid' check (status in ('paid','partial','waived')),
  recorded_by uuid references auth.users(id),
  notes text,
  created_at timestamptz not null default now()
);
create unique index if not exists payments_student_period_unique on public.payments (student_id, period);

alter table public.payments enable row level security;
-- No select/insert/update/delete policy for any role — admin-only, and only
-- through the RPCs below. This is deliberately more locked down than most
-- tables in this app: it's financial record-keeping, and the addendum asked
-- for it to be admin-only, not something a student ever reads directly.

-- ─── 3. Admin RPCs ───────────────────────────────────────────────────────────
create or replace function public.admin_get_payment_settings()
returns table(monthly_rate numeric)
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  perform public._assert_admin();
  return query select ps.monthly_rate from public.payment_settings ps where ps.id = true;
end $$;
revoke execute on function public.admin_get_payment_settings() from public, anon;
grant execute on function public.admin_get_payment_settings() to authenticated;

create or replace function public.admin_set_monthly_rate(p_rate numeric)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid;
begin
  v_actor := public._assert_admin();
  if p_rate is null or p_rate < 0 then raise exception 'rate must be a non-negative number'; end if;
  update public.payment_settings set monthly_rate = p_rate, updated_at = now() where id = true;
  insert into public.admin_audit_log(actor_id, actor_email, action, details)
  values (v_actor, auth.jwt()->>'email', 'set_monthly_rate', jsonb_build_object('rate', p_rate));
end $$;
revoke execute on function public.admin_set_monthly_rate(numeric) from public, anon;
grant execute on function public.admin_set_monthly_rate(numeric) to authenticated;

-- Upsert: one call whether this is the first record for the month or a
-- correction to an existing one (e.g. fixing a typo'd amount).
create or replace function public.admin_record_payment(p_student_id uuid, p_period text, p_amount numeric, p_status text default 'paid', p_notes text default null)
returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_actor uuid; v_target auth.users%rowtype;
begin
  v_actor := public._assert_admin();
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'invalid period, expected YYYY-MM'; end if;
  if p_status not in ('paid','partial','waived') then raise exception 'invalid status'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'amount must be a non-negative number'; end if;
  select * into v_target from auth.users u where u.id = p_student_id;
  if not found or coalesce(v_target.raw_user_meta_data->>'role','') <> 'student' then
    raise exception 'student not found';
  end if;
  insert into public.payments (student_id, amount, period, status, recorded_by, notes, paid_at)
  values (p_student_id, p_amount, p_period, p_status, v_actor, p_notes, now())
  on conflict (student_id, period) do update
    set amount = excluded.amount, status = excluded.status, notes = excluded.notes,
        recorded_by = excluded.recorded_by, paid_at = now();
  insert into public.admin_audit_log(actor_id, actor_email, action, target_user_id, target_email, details)
  values (v_actor, auth.jwt()->>'email', 'record_payment', p_student_id, v_target.email,
          jsonb_build_object('period', p_period, 'amount', p_amount, 'status', p_status));
end $$;
revoke execute on function public.admin_record_payment(uuid,text,numeric,text,text) from public, anon;
grant execute on function public.admin_record_payment(uuid,text,numeric,text,text) to authenticated;

-- The "who's paid / who hasn't, at a glance" view for one month: every
-- student, LEFT JOINed against their payment row for that period (so
-- students with no row show up as unpaid, not simply missing).
create or replace function public.admin_list_payment_status(p_period text)
returns table(student_id uuid, full_name text, group_name text, amount numeric, status text, paid_at timestamptz, notes text)
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  perform public._assert_admin();
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'invalid period, expected YYYY-MM'; end if;
  return query
    select p.id as student_id, p.full_name, p.group_name,
           pay.amount, coalesce(pay.status, 'unpaid') as status, pay.paid_at, pay.notes
    from public.profiles p
    left join public.payments pay on pay.student_id = p.id and pay.period = p_period
    where p.role = 'student'
    order by p.group_name, p.full_name;
end $$;
revoke execute on function public.admin_list_payment_status(text) from public, anon;
grant execute on function public.admin_list_payment_status(text) to authenticated;
