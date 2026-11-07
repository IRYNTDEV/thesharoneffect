# The Sharon Effect — website

## Files
- index.html — home
- book.html — booking (saves to Supabase, bank transfer, waits for Sharon)
- confirm.html — Sharon's web page to confirm payments (log in once on her phone)
- config.js — Supabase keys, WhatsApp number, bank details (all safe to be public)
- supabase/01_setup.sql — database setup (includes Sharon's email as staff)
- supabase/02_telegram.sql — Telegram alerts for Sharon
- supabase/telegram-webhook/index.ts — makes the Confirm buttons in Telegram work

Keep the assets/ folder next to the pages. Booking only works once the site is online.

## Telegram alerts — setup (about 10 minutes)

1. Create the bot (Sharon's phone or yours)
   - In Telegram, open @BotFather → send /newbot
   - Name: The Sharon Effect Bookings · Username: something ending in "bot", e.g. sharoneffect_bookings_bot
   - Copy the token it gives you (looks like 123456789:AAH...). Keep it private.

2. Make up a webhook secret
   - Any long random string, letters and numbers only, e.g. tse7Hq2pLx9Vw4Rk

3. Add the button handler in Supabase
   - Supabase → Edge Functions → Deploy a new function → Via editor
   - Name it exactly: telegram-webhook
   - Paste supabase/telegram-webhook/index.ts, deploy
   - Open the function's settings and turn OFF "Enforce JWT verification" (Telegram can't log in)
   - Edge Functions → Secrets → add:
     TELEGRAM_BOT_TOKEN = the token from step 1
     TELEGRAM_WEBHOOK_SECRET = the secret from step 2
     TELEGRAM_CHAT_ID = leave for now (step 5)

4. Connect Telegram to it — open this in a browser (replace the two parts):
   https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://obznamevdcfgggvfoayk.supabase.co/functions/v1/telegram-webhook&secret_token=<SECRET>
   You should see "Webhook was set".

5. Sharon opens the bot and taps Start
   - The bot replies with her chat ID number.
   - Add it as the secret TELEGRAM_CHAT_ID (step 3's Secrets page).

6. Turn on the alerts
   - SQL Editor → paste supabase/02_telegram.sql
   - Fill in the bot token, Sharon's chat ID and the live site address at the top → Run

Done. When a client taps "I've sent the money", Sharon gets a Telegram message with
✅ Payment received / ✖️ Not received buttons. Tapping one updates the client's page instantly.
