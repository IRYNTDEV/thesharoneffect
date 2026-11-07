-- ============================================================
-- The Sharon Effect — Telegram alerts for Sharon
-- Run AFTER supabase-setup.sql. Fill in the 3 values at the top, then Run.
-- Safe to run more than once.
-- ============================================================

create extension if not exists pg_net with schema extensions;

-- Private settings (this schema is not reachable from the website)
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);

insert into private.settings (key, value) values
  ('telegram_bot_token', 'PASTE_BOT_TOKEN_HERE'),          -- from @BotFather
  ('telegram_chat_id',   'PASTE_SHARON_CHAT_ID_HERE'),     -- the number the bot replies with after Sharon taps Start
  ('site_url',           'https://thesharoneffect.com')    -- the live website address, no slash at the end
on conflict (key) do update set value = excluded.value;

alter table public.bookings add column if not exists sent_at timestamptz;

create or replace function private.esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- Called by the booking page when the client taps "I've sent the money"
create or replace function public.mark_sent(p_token uuid)
returns json language plpgsql security definer set search_path = public, private, extensions as $$
declare
  b public.bookings; tok text; chat text; site text; txt text; kb jsonb;
begin
  select * into b from public.bookings where client_token = p_token;
  if not found or b.status <> 'pending' then return json_build_object('ok', false); end if;
  if b.sent_at is not null then return json_build_object('ok', true, 'repeat', true); end if;  -- only alert once

  update public.bookings set sent_at = now() where id = b.id;

  select value into tok  from private.settings where key = 'telegram_bot_token';
  select value into chat from private.settings where key = 'telegram_chat_id';
  select value into site from private.settings where key = 'site_url';
  if tok is null or tok like 'PASTE%' or chat is null or chat like 'PASTE%' then
    return json_build_object('ok', true, 'telegram', false);
  end if;

  txt := '💗 <b>New booking: payment sent</b>' || chr(10) || chr(10)
      || '<b>' || b.ref || '</b>' || chr(10)
      || private.esc(b.client_name) || ' · ' || private.esc(b.client_phone) || chr(10)
      || private.esc(b.service_name) || case when b.faces > 1 then ' × ' || b.faces else '' end || chr(10)
      || to_char(b.booking_date, 'Dy DD Mon YYYY') || ', ' || b.booking_time || chr(10)
      || private.esc(b.location_name) || coalesce(chr(10) || private.esc(b.address), '') || chr(10)
      || coalesce('Allergies: ' || private.esc(b.allergies) || chr(10), '')
      || chr(10)
      || 'Check OPay for <b>₦' || to_char(b.deposit, 'FM999,999,999') || '</b> with note <b>' || b.ref || '</b>'
      || case when b.price_is_from then chr(10) || '(total from ₦' else chr(10) || '(total ₦' end
      || to_char(b.total, 'FM999,999,999') || ')';

  kb := jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', '✅ Payment received', 'callback_data', 'c:' || b.id),
          jsonb_build_object('text', '✖️ Not received',     'callback_data', 'd:' || b.id)));
  if site like 'https://%' then
    kb := kb || jsonb_build_array(jsonb_build_array(jsonb_build_object('text', 'Open booking', 'url', rtrim(site, '/') || '/confirm.html?b=' || b.id)));
  end if;

  perform net.http_post(
    url     := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body    := jsonb_build_object('chat_id', chat, 'text', txt, 'parse_mode', 'HTML',
                                  'disable_web_page_preview', true,
                                  'reply_markup', jsonb_build_object('inline_keyboard', kb)),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  return json_build_object('ok', true, 'telegram', true);
end;
$$;

grant execute on function public.mark_sent(uuid) to anon, authenticated;
