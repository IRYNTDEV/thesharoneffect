// The Sharon Effect — Telegram button handler (Supabase Edge Function "telegram-webhook")
// Turn OFF "Enforce JWT verification" for this function. Secrets it reads:
//   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_WEBHOOK_SECRET
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const CHAT = Deno.env.get("TELEGRAM_CHAT_ID") ?? "";
const SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const ok = () => new Response("ok");
const tg = (method: string, body: unknown) =>
  fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
const waNumber = (p: string) => {
  let d = String(p || "").replace(/\D/g, "");
  if (d.startsWith("0")) d = "234" + d.slice(1);
  return d;
};
const niceDate = (d: string) =>
  new Date(d + "T00:00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });

Deno.serve(async (req) => {
  if (SECRET && req.headers.get("x-telegram-bot-api-secret-token") !== SECRET) {
    return new Response("forbidden", { status: 403 });
  }
  const u = await req.json().catch(() => ({}));

  // /start: tell Sharon her chat ID so it can be added to the setup
  const text: string | undefined = u.message?.text;
  if (text && text.startsWith("/start")) {
    const id = u.message.chat.id;
    const known = CHAT && String(id) === String(CHAT);
    await tg("sendMessage", {
      chat_id: id,
      text: known
        ? "You're all set ♡ New bookings will arrive here with Confirm buttons."
        : `Hi! Your chat ID is ${id}\n\nSend this number to your web designer to finish setting up booking alerts.`,
    });
    return ok();
  }

  const cq = u.callback_query;
  if (!cq) return ok();
  if (String(cq.from?.id) !== String(CHAT)) {
    await tg("answerCallbackQuery", { callback_query_id: cq.id, text: "Only Sharon can do this." });
    return ok();
  }

  const [act, id] = String(cq.data || "").split(":");
  const status = act === "c" ? "confirmed" : act === "d" ? "declined" : null;
  if (!status || !id) {
    await tg("answerCallbackQuery", { callback_query_id: cq.id });
    return ok();
  }

  const { data: b } = await db
    .from("bookings")
    .update({ status, status_at: new Date().toISOString() })
    .eq("id", id)
    .eq("status", "pending")
    .select()
    .maybeSingle();

  if (!b) {
    const { data: cur } = await db.from("bookings").select("status").eq("id", id).maybeSingle();
    await tg("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: cur ? `This booking is already ${cur.status}.` : "Booking not found.",
      show_alert: true,
    });
    return ok();
  }

  const first = String(b.client_name).split(" ")[0];
  const msg = status === "confirmed"
    ? `Hi ${first} ♡ your booking ${b.ref} is confirmed for ${niceDate(b.booking_date)}, ${b.booking_time}. Can't wait to see you! — Sharon`
    : `Hi ${first}, this is Sharon from The Sharon Effect about booking ${b.ref}. I couldn't find your transfer yet. Could you send me the receipt again?`;
  const wa = `https://wa.me/${waNumber(b.client_phone)}?text=${encodeURIComponent(msg)}`;

  await tg("answerCallbackQuery", {
    callback_query_id: cq.id,
    text: status === "confirmed" ? "Confirmed ✓ The client's page has updated." : "Marked as not received.",
  });
  await tg("editMessageText", {
    chat_id: cq.message.chat.id,
    message_id: cq.message.message_id,
    text: `${cq.message.text}\n\n${status === "confirmed" ? "✅ CONFIRMED" : "✖️ MARKED NOT RECEIVED"}`,
    entities: cq.message.entities,
    disable_web_page_preview: true,
    reply_markup: { inline_keyboard: [[{ text: `Message ${first} on WhatsApp`, url: wa }]] },
  });
  return ok();
});
