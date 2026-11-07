-- ============================================================
-- The Sharon Effect — booking reminders on Telegram
-- Run AFTER 01_setup.sql and 02_telegram.sql.
-- Reuses the bot token, chat ID and pg_net already set up for alerts.
-- Safe to run more than once.
-- ============================================================

-- pg_cron runs the two scheduled checks below. If this line errors with a
-- permission error, go to Supabase → Database → Extensions, enable "pg_cron",
-- then run this file again.
create extension if not exists pg_cron with schema extensions;

alter table public.bookings add column if not exists reminder_morning_sent boolean not null default false;
alter table public.bookings add column if not exists reminder_2h_sent      boolean not null default false;

-- Turns booking_date + booking_time ("2:00 PM") into a real timestamp, Lagos time
create or replace function private.appointment_at(p_date date, p_time text)
returns timestamptz language sql immutable as $$
  select (p_date + to_timestamp(p_time, 'HH12:MI AM')::time) at time zone 'Africa/Lagos';
$$;

-- Once a day: one message listing everything confirmed for today
create or replace function private.send_morning_reminders()
returns void language plpgsql security definer set search_path = public, private, extensions as $$
declare
  tok text; chat text; lines text; n int;
begin
  select value into tok  from private.settings where key = 'telegram_bot_token';
  select value into chat from private.settings where key = 'telegram_chat_id';
  if tok is null or tok like 'PASTE%' or chat is null or chat like 'PASTE%' then return; end if;

  select string_agg(b.booking_time || ' — ' || private.esc(b.client_name) || ' — ' || private.esc(b.service_name) || ' (' || b.ref || ')', chr(10) order by b.booking_time),
         count(*)
    into lines, n
  from public.bookings b
  where b.status = 'confirmed' and b.reminder_morning_sent = false
    and b.booking_date = (now() at time zone 'Africa/Lagos')::date;

  if n is null or n = 0 then return; end if;

  perform net.http_post(
    url     := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body    := jsonb_build_object('chat_id', chat, 'parse_mode', 'HTML',
                 'text', '🗓️ <b>Today''s bookings (' || n || ')</b>' || chr(10) || chr(10) || lines),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );

  update public.bookings set reminder_morning_sent = true
  where status = 'confirmed' and reminder_morning_sent = false
    and booking_date = (now() at time zone 'Africa/Lagos')::date;
end;
$$;

-- Every 10 minutes: nudge for anything confirmed starting in about 2 hours
create or replace function private.send_2h_reminders()
returns void language plpgsql security definer set search_path = public, private, extensions as $$
declare
  tok text; chat text; b record;
begin
  select value into tok  from private.settings where key = 'telegram_bot_token';
  select value into chat from private.settings where key = 'telegram_chat_id';
  if tok is null or tok like 'PASTE%' or chat is null or chat like 'PASTE%' then return; end if;

  for b in
    select * from public.bookings
    where status = 'confirmed' and reminder_2h_sent = false
      and private.appointment_at(booking_date, booking_time) > now()
      and private.appointment_at(booking_date, booking_time) <= now() + interval '2 hours'
  loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || tok || '/sendMessage',
      body    := jsonb_build_object('chat_id', chat, 'parse_mode', 'HTML',
                   'text', '⏰ <b>' || private.esc(b.client_name) || '</b> at ' || b.booking_time || ' today' || chr(10)
                        || private.esc(b.service_name) || ' · ' || private.esc(b.location_name) || chr(10)
                        || b.ref),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
    update public.bookings set reminder_2h_sent = true where id = b.id;
  end loop;
end;
$$;

-- If a booking is moved off "confirmed" (e.g. Sharon reopens it), clear its
-- reminder flags so a later re-confirm sends fresh reminders.
create or replace function private.reset_reminders_on_unconfirm()
returns trigger language plpgsql as $$
begin
  if new.status <> 'confirmed' and old.status = 'confirmed' then
    new.reminder_morning_sent := false;
    new.reminder_2h_sent := false;
  end if;
  return new;
end;
$$;

drop trigger if exists tse_reset_reminders on public.bookings;
create trigger tse_reset_reminders before update on public.bookings
for each row execute function private.reset_reminders_on_unconfirm();

-- Schedule both jobs (replacing any previous schedule of the same name)
select cron.unschedule(jobid) from cron.job where jobname = 'tse-morning-reminder';
select cron.schedule('tse-morning-reminder', '0 6 * * *', $$select private.send_morning_reminders();$$);

select cron.unschedule(jobid) from cron.job where jobname = 'tse-2h-reminder';
select cron.schedule('tse-2h-reminder', '*/10 * * * *', $$select private.send_2h_reminders();$$);
