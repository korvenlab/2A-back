import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";

const app = new Hono();

const rawOrigins = process.env.FRONTEND_ORIGIN?.trim();
const allowOrigin =
  !rawOrigins || rawOrigins === "*"
    ? "*"
    : rawOrigins.split(",").map((s) => s.trim()).filter(Boolean);

app.use(
  "*",
  cors({
    origin: allowOrigin,
    allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
  }),
);

app.get("/health", (c) => c.json({ ok: true }));

app.get("/", (c) =>
  c.json({
    service: "2avendas-backend",
    hint: "API HTTP para integrações futuras. O app web hoje fala com Supabase no browser.",
  }),
);

const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`2avendas-backend listening on ${info.address}:${info.port}`);
});
