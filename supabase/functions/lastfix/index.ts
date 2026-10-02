// 最後の居場所：友だちとの部屋ごと・人ごとに、暗号化した居場所を1つだけ残す。
// 相手のアプリが閉じていても、開いたときに「最後にいた所」が見えるように（10/3 本人「ゼンリー見習いなよ」）。
// 受け取るのは 部屋（32桁）・送り主（16桁）・暗号文 だけ。鍵は2台の端末にしか無く、ここでは読めない。
// POST {room, sender, blob} … 自分の行を上書き
// GET  ?room=…            … その部屋の行を全部（多くて数行）。部屋の名前を知らなければ読めない
import { createClient } from "npm:@supabase/supabase-js@2";

const PUBLISHABLE = "sb_publishable_iT6waNVeHj-Kb0Rp_Ux90w_1VCCk-WK";
const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
const ROOM = /^[0-9a-f]{32}$/;
const SENDER = /^[0-9a-f]{16}$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  // アプリからの呼び出しだけを通す（公開してよい鍵だが、でたらめな呼び出しは弾く）。
  if (req.headers.get("apikey") !== PUBLISHABLE) return json({ error: "forbidden" }, 403);

  if (req.method === "GET") {
    const room = new URL(req.url).searchParams.get("room") ?? "";
    if (!ROOM.test(room)) return json({ error: "bad room" }, 400);
    const { data, error } = await db.from("last_fix").select("sender, blob, updated_at").eq("room", room).limit(10);
    if (error) return json({ error: "read failed" }, 500);
    return json({ rows: data ?? [] });
  }

  if (req.method === "POST") {
    let input: { room?: string; sender?: string; blob?: string };
    try {
      input = await req.json();
    } catch {
      return json({ error: "bad json" }, 400);
    }
    const room = String(input.room ?? "");
    const sender = String(input.sender ?? "");
    const blob = String(input.blob ?? "");
    if (!ROOM.test(room) || !SENDER.test(sender)) return json({ error: "bad id" }, 400);
    if (!/^[A-Za-z0-9+/=]{20,1000}$/.test(blob)) return json({ error: "bad blob" }, 400);
    const { error } = await db.from("last_fix")
      .upsert({ room, sender, blob, updated_at: new Date().toISOString() }, { onConflict: "room,sender" });
    if (error) return json({ error: "write failed" }, 500);
    // 30日だれも書いていない部屋の行は消す（居場所の暗号文を長く置かない）。
    await db.from("last_fix").delete().lt("updated_at", new Date(Date.now() - 30 * 86400_000).toISOString());
    return json({ ok: true });
  }

  return json({ error: "GET or POST" }, 405);
});
