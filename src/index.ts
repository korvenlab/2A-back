import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { dashboardRoute } from "./dashboard-route.js";
import { jsonOk } from "./json-response.js";
import { metricsRoute } from "./metrics-route.js";

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
    allowHeaders: ["Content-Type", "Authorization", "X-API-Key", "x-admin-secret"],
  }),
);

app.get("/health", (c) => jsonOk(c, { ok: true }));

app.get("/", (c) =>
  jsonOk(c, {
    ok: true,
    service: "2avendas-backend",
    hint: "Dashboard executivo: GET /dashboard | KPIs simples: GET /metrics | Saúde: GET /health",
  }),
);

app.route("/metrics", metricsRoute);
app.route("/dashboard", dashboardRoute);

const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`2avendas-backend listening on ${info.address}:${info.port}`);
});
