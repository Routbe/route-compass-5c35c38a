-- 0218 — Booking engine phase 2: slot soft-locks, scheduling limits and gap-free slots.
--
--   * booking_holds: clicking a slot reserves it for 5 minutes. Holds live on the same
--     (host, UTC day) advisory locks as bookings, carry a secret only the holder knows
--     (stored as sha256), are capped at 3 live holds per client and count against
--     overlap, seats and limits for everyone else. GiST keeps non-shared holds apart.
--   * limits per day / week / month (per host, in the type's zone; week = ISO Monday),
--     a cap of active future bookings per guest e-mail, a rolling horizon counted in
--     business days (Mon–Fri) and "adjacent only" starts that never leave gaps.
--   * rout_booking_create gains (hold, secret); the 7-argument form stays as a wrapper.
-- Every rule is enforced here; the slot list only mirrors it. Idempotent.

alter table public.booking_event_types
  add column if not exists limit_per_day integer,
  add column if not exists limit_per_week integer,
  add column if not exists limit_per_month integer,
  add column if not exists limit_per_guest integer,
  add column if not exists horizon_business_days integer,
  add column if not exists adjacent_only boolean not null default false,
  add column if not exists rules_timezone text;
do $$ begin
  alter table public.booking_event_types add constraint booking_event_types_phase2_ranges check (
    (limit_per_day is null or limit_per_day between 1 and 200)
    and (limit_per_week is null or limit_per_week between 1 and 1000)
    and (limit_per_month is null or limit_per_month between 1 and 5000)
    and (limit_per_guest is null or limit_per_guest between 1 and 50)
    and (horizon_business_days is null or horizon_business_days between 1 and 260)
    and (rules_timezone is null or char_length(rules_timezone) between 1 and 64));
exception when duplicate_object then null; end $$;

create table if not exists public.booking_holds (
  hold_id uuid not null,
  host_user_id uuid not null references public.users (id) on delete cascade,
  event_type_id uuid not null references public.booking_event_types (id) on delete cascade,
  start_utc timestamptz not null,
  block_start_utc timestamptz not null,
  block_end_utc timestamptz not null,
  shared_slot boolean not null default false,
  secret_digest bytea not null check (octet_length(secret_digest) = 32),
  client_digest bytea not null check (octet_length(client_digest) = 32),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (hold_id, host_user_id),
  check (block_end_utc > block_start_utc and block_start_utc <= start_utc and expires_at > created_at)
);
do $$ begin
  alter table public.booking_holds add constraint booking_holds_no_overlap exclude using gist (
    host_user_id with =, tstzrange(block_start_utc, block_end_utc, '[)') with &&
  ) where (not shared_slot);
exception when duplicate_object or duplicate_table then null; end $$;
create index if not exists booking_holds_host_time on public.booking_holds (host_user_id, block_start_utc);
create index if not exists booking_holds_expiry on public.booking_holds (expires_at);
create index if not exists booking_holds_client on public.booking_holds (client_digest, expires_at);

-- Holds carry no guest data. Hosts may read the holds on their own timeline; every
-- write goes through the definer functions below.
alter table public.booking_holds enable row level security;
revoke all on public.booking_holds from public;
drop policy if exists rout_owner_read on public.booking_holds;
create policy rout_owner_read on public.booking_holds for select
  using (host_user_id = public.rout_current_user_id());
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'rout_app') then
    revoke all on public.booking_holds from rout_app;
    grant select on public.booking_holds to rout_app;
  end if;
end $$;

-- ---------- building blocks (internal) ----------

-- The zone a type's calendar periods and business days are counted in.
create or replace function public.rout_booking_zone(p_zone text, p_host uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select p_zone where p_zone is not null and exists (select 1 from pg_timezone_names z where z.name = p_zone)),
    (select r.timezone from public.availability_rules r
      where r.user_id = p_host and exists (select 1 from pg_timezone_names z where z.name = r.timezone)
      order by r.weekday, r.start_minute, r.id limit 1),
    'UTC')
$$;

-- The type's zone for type-wide rules (horizon): own zone, else the first host's.
create or replace function public.rout_booking_type_zone(p_event_type uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select public.rout_booking_zone(t.rules_timezone,
    coalesce(t.user_id, (select h.user_id from public.booking_event_type_hosts h where h.event_type_id = t.id
      order by h.priority desc, h.user_id limit 1)))
  from public.booking_event_types t where t.id = p_event_type
$$;

-- Last bookable instant (exclusive). Business days: Mon–Fri in p_zone, today counts
-- when it is one; the window ends at local midnight after the n-th business day.
-- Never beyond max_days_ahead (the cached horizon).
create or replace function public.rout_booking_horizon_end(p_business_days integer, p_max_days integer, p_zone text, p_now timestamptz)
returns timestamptz language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d date; n integer := 0; cap timestamptz := p_now + make_interval(days => p_max_days);
begin
  if p_business_days is null then return cap; end if;
  d := (p_now at time zone p_zone)::date;
  loop
    if extract(isodow from d) < 6 then n := n + 1; end if;
    exit when n >= p_business_days;
    d := d + 1;
  end loop;
  return least(cap, ((d + 1)::timestamp) at time zone p_zone);
end $$;

-- A 15-minute edge slot is taken: cache says busy (or missing) or an active booking covers it.
create or replace function public.rout_booking_edge_busy(p_host uuid, p_from timestamptz, p_to timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select not public.rout_booking_cache_free(p_host, p_from, p_to)
    or exists (select 1 from public.bookings b where b.host_user_id = p_host
      and b.status in ('held','pending_payment','requested','confirmed')
      and tstzrange(b.block_start_utc, b.block_end_utc, '[)') && tstzrange(p_from, p_to, '[)'))
$$;

-- Gap-free: the block touches something taken (or the edge of working hours) on either side.
-- Slot indices match the bitmap: floor(block start), ceil(block end) on the 15-minute grid.
create or replace function public.rout_booking_adjacent_ok(p_host uuid, p_block_start timestamptz, p_block_end timestamptz)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  with g as (select floor(extract(epoch from p_block_start) / 900)::bigint as a, ceil(extract(epoch from p_block_end) / 900)::bigint as b)
  select public.rout_booking_edge_busy(p_host, to_timestamp((g.a - 1) * 900), to_timestamp(g.a * 900))
      or public.rout_booking_edge_busy(p_host, to_timestamp(g.b * 900), to_timestamp((g.b + 1) * 900))
  from g
$$;

-- Live freedom including other visitors' holds; seats count bookings + holds together.
create or replace function public.rout_booking_host_free_held(p_host uuid, p_event_type uuid, p_start timestamptz,
  p_block_start timestamptz, p_block_end timestamptz, p_capacity integer, p_hold uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.rout_booking_host_free(p_host, p_event_type, p_start, p_block_start, p_block_end, p_capacity)
    and not exists (
      select 1 from public.booking_holds x where x.host_user_id = p_host and x.expires_at > now()
        and x.hold_id is distinct from p_hold
        and tstzrange(x.block_start_utc, x.block_end_utc, '[)') && tstzrange(p_block_start, p_block_end, '[)')
        and not (p_capacity > 1 and x.shared_slot and x.event_type_id = p_event_type and x.start_utc = p_start))
    and (p_capacity <= 1 or (
      (select count(*) from public.bookings b where b.host_user_id = p_host and b.shared_slot
        and b.event_type_id = p_event_type and b.start_utc = p_start
        and b.status in ('held','pending_payment','requested','confirmed'))
      + (select count(*) from public.booking_holds x where x.host_user_id = p_host and x.shared_slot
        and x.event_type_id = p_event_type and x.start_utc = p_start and x.expires_at > now()
        and x.hold_id is distinct from p_hold)) < p_capacity)
$$;

-- Meetings of this type for this host (bookings + live holds of others) in the calendar
-- period containing p_start stay under each limit. A shared start is one meeting, and
-- joining an existing shared start never adds one.
create or replace function public.rout_booking_within_limits(p_event_type uuid, p_host uuid, p_start timestamptz, p_hold uuid)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  t public.booking_event_types%rowtype; zone text; local timestamp; unit text; lim integer;
  ps timestamptz; pe timestamptz; n integer; mine text;
begin
  select * into t from public.booking_event_types where id = p_event_type;
  if t.limit_per_day is null and t.limit_per_week is null and t.limit_per_month is null then return true; end if;
  zone := public.rout_booking_zone(t.rules_timezone, p_host);
  local := p_start at time zone zone;
  mine := case when greatest(1, t.resource_capacity) > 1 then 'S' || p_start::text end;
  foreach unit in array array['day', 'week', 'month'] loop
    lim := case unit when 'day' then t.limit_per_day when 'week' then t.limit_per_week else t.limit_per_month end;
    continue when lim is null;
    ps := date_trunc(unit, local) at time zone zone;
    pe := (date_trunc(unit, local) + ('1 ' || unit)::interval) at time zone zone;
    with keys as (
      select case when b.shared_slot then 'S' || b.start_utc::text else b.id::text end as k
      from public.bookings b where b.host_user_id = p_host and b.event_type_id = t.id
        and b.status in ('held','pending_payment','requested','confirmed') and b.start_utc >= ps and b.start_utc < pe
      union
      select case when x.shared_slot then 'S' || x.start_utc::text else 'H' || x.hold_id::text end
      from public.booking_holds x where x.host_user_id = p_host and x.event_type_id = t.id and x.expires_at > now()
        and x.hold_id is distinct from p_hold and x.start_utc >= ps and x.start_utc < pe)
    select count(*), bool_or(k = mine) into n, local from (select k, null::timestamp from keys) q(k, z)
      left join lateral (select 1) l on true;
    -- reuse of `local` above is avoided: recompute it after the query
    local := p_start at time zone zone;
    if mine is not null and exists (
      select 1 from public.bookings b where b.host_user_id = p_host and b.event_type_id = t.id and b.shared_slot
        and b.start_utc = p_start and b.status in ('held','pending_payment','requested','confirmed')) then
      continue;
    end if;
    if n >= lim then return false; end if;
  end loop;
  return true;
end $$;
