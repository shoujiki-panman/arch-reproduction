// 呼び鈴：友だちが「つなぐ」を押したとき、相手の iPhone に Apple のプッシュ通知で知らせる。
// kind が "errand" のときは、家のアレクサに言った買い物（text）を知らせる（10/3 追加）。
// 受け取るのは 宛先（device token）・環境・送り主の名札・名前・買い物の言葉 だけ。居場所は来ない。
// 鍵（.p8）は Supabase の Secrets（APNS_KEY_ID / APNS_TEAM_ID / APNS_PRIVATE_KEY）に置き、ここには書かない。
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

const TOPIC = "jp.shutanuma.kokodayo";
const PUBLISHABLE = "sb_publishable_iT6waNVeHj-Kb0Rp_Ux90w_1VCCk-WK";

let cached: { jwt: string; at: number } | null = null;
const lastSent = new Map<string, number>();

// Apple の決まり：同じ認証トークンは20〜60分使い回す（作りすぎると断られる）。
async function authToken(): Promise<string> {
  if (cached && Date.now() - cached.at < 40 * 60 * 1000) return cached.jwt;
  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const pem = (Deno.env.get("APNS_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(key);
  cached = { jwt, at: Date.now() };
  return jwt;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  // アプリからの呼び出しだけを通す（公開してよい鍵だが、でたらめな呼び出しは弾く）。
  if (req.headers.get("apikey") !== PUBLISHABLE) return json({ error: "forbidden" }, 403);
  let input: { to?: string; env?: string; from?: string; name?: string; kind?: string; text?: string };
  try {
    input = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const to = String(input.to ?? "");
  if (!/^[0-9a-f]{64,200}$/.test(to)) return json({ error: "bad token" }, 400);
  const errand = input.kind === "errand";
  const text = String(input.text ?? "").trim().slice(0, 60);
  if (errand && !text) return json({ error: "no text" }, 400);
  // 同じ相手に、呼び鈴は20秒・買い物は5秒に1回まで（連打で相手の電話を鳴らし続けない）。
  const now = Date.now();
  const slot = `${errand ? "errand" : "knock"}:${to}`;
  if (now - (lastSent.get(slot) ?? 0) < (errand ? 5_000 : 20_000)) return json({ ok: true, skipped: "too soon" });
  lastSent.set(slot, now);

  const name = String(input.name ?? "友だち").slice(0, 20);
  const from = String(input.from ?? "").slice(0, 64);
  const host = input.env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const payload = errand
    ? {
        aps: { alert: { title: `🛒 ${text}`, body: `${name}からの買い物のお願いです` }, sound: "default" },
        errand: text,
      }
    : {
        aps: {
          alert: { title: `${name}がつなごうとしています`, body: "開いて「つなぐ」を押すと、お互いの居場所が見えます" },
          sound: "default",
        },
        knock: from,
      };
  const res = await fetch(`https://${host}/3/device/${to}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await authToken()}`,
      "apns-topic": TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  if (res.status === 200) return json({ ok: true });
  return json({ ok: false, status: res.status, reason: await res.text() }, 502);
});
