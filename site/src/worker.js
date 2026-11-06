// Waitlist endpoint. Stores email + optional medium. No IP, no UA, no analytics.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MEDIA = new Set(["music", "visual", "writing", "film", "other"]);

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

async function readForm(request) {
  const type = request.headers.get("content-type") || "";
  if (type.includes("application/json")) return await request.json();
  return Object.fromEntries(await request.formData());
}

async function waitlist(request, env) {
  let data;
  try {
    data = await readForm(request);
  } catch {
    return json({ ok: false, error: "bad request" }, 400);
  }

  // Honeypot: bots fill hidden field. Pretend success.
  if (data.website) return json({ ok: true });

  const email = String(data.email || "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) {
    return json({ ok: false, error: "invalid email" }, 400);
  }
  const medium = MEDIA.has(data.medium) ? data.medium : null;

  // Duplicate -> same 200, so signup status isn't leaked.
  await env.DB.prepare(
    "INSERT INTO waitlist (email, medium) VALUES (?, ?) ON CONFLICT(email) DO NOTHING"
  )
    .bind(email, medium)
    .run();

  return json({ ok: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/waitlist") {
      if (request.method !== "POST") return json({ ok: false }, 405);
      return waitlist(request, env);
    }
    return env.ASSETS.fetch(request);
  },
};
