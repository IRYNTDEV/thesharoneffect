-- ============================================================
-- The Sharon Effect — booking system setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.
-- ============================================================

-- ---------- Price list (the database computes every total, so nobody can edit the price in their browser)
create table if not exists public.services (
  id         text primary key,
  name       text not null,
  mode       text not null check (mode in ('zone','fixed','from')),
  price      integer,               -- naira; null for zone-priced services
  per_face   boolean not null default false,
  locs       text not null check (locs in ('any','studio','online'))
);

create table if not exists public.locations (
  id     text primary key,
  name   text not null,
  price  integer not null           -- naira, used for zone-priced services
);

insert into public.services (id, name, mode, price, per_face, locs) values
  ('glam',      'Birthday / occasion glam',     'zone',  null,   true,  'any'),
  ('shoot',     'Studio photoshoot glam',       'fixed', 30000,  true,  'studio'),
  ('trial',     'Bridal consultation & trial',  'fixed', 45000,  false, 'any'),
  ('bride',     'Bride (wedding day glam)',     'fixed', 170000, false, 'any'),
  ('fullday',   'Full-day bridal booking',      'fixed', 200000, false, 'any'),
  ('party',     'Bridesmaids / bridal party',   'fixed', 40000,  true,  'any'),
  ('editorial', 'Editorial / creative makeup',  'from',  50000,  true,  'any'),
  ('campaign',  'Campaign / portfolio shoot',   'from',  100000, false, 'any'),
  ('screen',    'Brand, music video or TV',     'from',  350000, false, 'any'),
  ('t2w',       '2-week beginner training',     'fixed', 150000, false, 'studio'),
  ('t1m',       '1-month beginner training',    'fixed', 250000, false, 'studio'),
  ('t2m',       '2-month beginner training',    'fixed', 400000, false, 'studio'),
  ('virtual',   'Virtual 1-on-1 class',         'fixed', 120000, false, 'online')
on conflict (id) do update set name = excluded.name, mode = excluded.mode, price = excluded.price,
  per_face = excluded.per_face, locs = excluded.locs;

insert into public.locations (id, name, price) values
  ('studio',   'Studio, Ojo',             30000),
  ('ojo',      'Home service (Ojo axis)', 55000),
  ('mainland', 'Home service (Mainland)', 90000),
  ('island',   'Home service (Island)',   120000),
  ('online',   'Online',                  0)
on conflict (id) do update set name = excluded.name, price = excluded.price;

-- ---------- Bookings
create table if not exists public.bookings (
  id             uuid primary key default gen_random_uuid(),
  ref            text not null unique,
  client_token   uuid not null unique default gen_random_uuid(),  -- secret the client's page uses to watch its status
  status         text not null default 'pending'
                 check (status in ('pending','confirmed','declined','expired','cancelled')),
  service_id     text not null references public.services(id),
  service_name   text not null,
  location_id    text not null references public.locations(id),
  location_name  text not null,
  address        text,
  booking_date   date not null,
  booking_time   text not null,
  faces          integer not null default 1 check (faces between 1 and 20),
  total          integer not null,
  deposit        integer not null,
  price_is_from  boolean not null default false,
  client_name    text not null,
  client_phone   text not null,
  client_email   text,
  event          text,
  allergies      text,
  photo_ok       boolean not null default false,
  created_at     timestamptz not null default now(),
  status_at      timestamptz
);
create index if not exists bookings_slot_idx on public.bookings (booking_date, booking_time, status);

-- ---------- Who counts as Sharon (staff). Add her login email at the bottom of this file.
create table if not exists public.staff (
  email text primary key
);

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- ---------- Lock everything down, then open only what's needed
alter table public.services  enable row level security;
alter table public.locations enable row level security;
alter table public.bookings  enable row level security;
alter table public.staff     enable row level security;

revoke all on public.services, public.locations, public.bookings, public.staff from anon, authenticated;
grant select on public.services, public.locations to anon, authenticated;
grant select, update on public.bookings to authenticated;

drop policy if exists "price list is public" on public.services;
create policy "price list is public" on public.services for select using (true);
drop policy if exists "locations are public" on public.locations;
create policy "locations are public" on public.locations for select using (true);
drop policy if exists "staff read bookings" on public.bookings;
create policy "staff read bookings" on public.bookings for select to authenticated using (public.is_staff());
drop policy if exists "staff update bookings" on public.bookings;
create policy "staff update bookings" on public.bookings for update to authenticated using (public.is_staff()) with check (public.is_staff());

-- Pending bookings hold their slot for this long before they expire
create or replace function public._hold_window() returns interval language sql immutable as $$ select interval '6 hours' $$;

create or replace function public._expire_stale() returns void
language sql security definer set search_path = public as $$
  update public.bookings set status = 'expired', status_at = now()
  where status = 'pending' and created_at < now() - public._hold_window();
$$;

-- ---------- Client: create a booking (prices are computed here, not in the browser)
create or replace function public.create_booking(
  p_service text, p_location text, p_date date, p_time text, p_faces integer,
  p_name text, p_phone text, p_email text default null, p_event text default null,
  p_address text default null, p_allergies text default null, p_photo_ok boolean default false
) returns json
language plpgsql security definer set search_path = public as $$
declare
  s public.services; l public.locations;
  v_faces integer; v_unit integer; v_total integer; v_ref text; v_row public.bookings;
begin
  select * into s from public.services where id = p_service;
  if not found then raise exception 'Unknown service'; end if;
  select * into l from public.locations where id = p_location;
  if not found then raise exception 'Unknown location'; end if;

  if s.locs = 'studio' and l.id <> 'studio' then raise exception 'This service is studio only'; end if;
  if s.locs = 'online' and l.id <> 'online' then raise exception 'This service is online only'; end if;
  if s.locs = 'any' and l.id = 'online' then raise exception 'Choose the studio or a home service zone'; end if;
  if l.id in ('ojo','mainland','island') and coalesce(length(trim(p_address)), 0) < 5 then raise exception 'Add your full address'; end if;
  if p_date < (now() at time zone 'Africa/Lagos')::date then raise exception 'That date has passed'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 or coalesce(length(trim(p_phone)), 0) < 7 then raise exception 'Add your name and WhatsApp number'; end if;

  v_faces := case when s.per_face then greatest(1, least(coalesce(p_faces, 1), 20)) else 1 end;
  v_unit  := case when s.mode = 'zone' then l.price else s.price end;
  v_total := v_unit * v_faces;

  -- one sitting per time slot: lock the slot, then check it
  perform pg_advisory_xact_lock(hashtext(p_date::text || p_time));
  perform public._expire_stale();
  if exists (select 1 from public.bookings
             where booking_date = p_date and booking_time = p_time and status in ('pending','confirmed')) then
    raise exception 'Sorry, that time was just taken. Please pick another slot.';
  end if;

  loop
    v_ref := 'TSE-' || to_char(p_date, 'DDMM') || '-' || upper(substr(md5(random()::text), 1, 4));
    exit when not exists (select 1 from public.bookings where ref = v_ref);
  end loop;

  insert into public.bookings (ref, service_id, service_name, location_id, location_name, address,
    booking_date, booking_time, faces, total, deposit, price_is_from,
    client_name, client_phone, client_email, event, allergies, photo_ok)
  values (v_ref, s.id, s.name, l.id, l.name, nullif(trim(p_address), ''),
    p_date, p_time, v_faces, v_total, ceil(v_total / 2.0)::integer, s.mode = 'from',
    trim(p_name), trim(p_phone), nullif(trim(p_email), ''), nullif(trim(p_event), ''), nullif(trim(p_allergies), ''), coalesce(p_photo_ok, false))
  returning * into v_row;

  return json_build_object('id', v_row.id, 'ref', v_row.ref, 'token', v_row.client_token,
    'total', v_row.total, 'deposit', v_row.deposit, 'price_is_from', v_row.price_is_from,
    'service', v_row.service_name, 'location', v_row.location_name,
    'date', v_row.booking_date, 'time', v_row.booking_time, 'faces', v_row.faces);
end;
$$;

-- ---------- Client: check my booking's status (needs the secret token, returns no one else's data)
create or replace function public.booking_status(p_token uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object('ref', ref, 'status', status, 'status_at', status_at,
    'service', service_name, 'date', booking_date, 'time', booking_time, 'deposit', deposit)
  from public.bookings where client_token = p_token;
$$;

-- ---------- Anyone: which slots are taken (dates and times only, no personal details)
create or replace function public.taken_slots(p_from date, p_to date)
returns table (booking_date date, booking_time text)
language sql security definer set search_path = public as $$
  select b.booking_date, b.booking_time from public.bookings b
  where b.booking_date between p_from and p_to
    and (b.status = 'confirmed' or (b.status = 'pending' and b.created_at >= now() - public._hold_window()));
$$;

-- ---------- Sharon: confirm or decline (checks she is staff)
create or replace function public.set_booking_status(p_id uuid, p_status text)
returns json language plpgsql security definer set search_path = public as $$
declare v_row public.bookings;
begin
  if not public.is_staff() then raise exception 'Only The Sharon Effect can confirm bookings'; end if;
  if p_status not in ('confirmed','declined','cancelled','pending') then raise exception 'Unknown status'; end if;
  update public.bookings set status = p_status, status_at = now() where id = p_id returning * into v_row;
  if not found then raise exception 'Booking not found'; end if;
  return json_build_object('ref', v_row.ref, 'status', v_row.status);
end;
$$;

-- ---------- Keep-alive: pinged daily so the free project never pauses (also tidies stale holds)
create or replace function public.ping()
returns text language plpgsql security definer set search_path = public as $$
begin
  perform public._expire_stale();
  return 'ok';
end;
$$;

-- Function permissions: clients may call these four; internal helpers stay private
revoke execute on function public._expire_stale() from public, anon, authenticated;
grant execute on function public.create_booking(text, text, date, text, integer, text, text, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.booking_status(uuid) to anon, authenticated;
grant execute on function public.taken_slots(date, date) to anon, authenticated;
grant execute on function public.ping() to anon, authenticated;
grant execute on function public.set_booking_status(uuid, text) to authenticated;
grant execute on function public.is_staff() to authenticated;

-- ============================================================
-- LAST STEP: put Sharon's login email here, then run.
-- ============================================================
insert into public.staff (email) values ('prospersharon256@gmail.com') on conflict do nothing;
