import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { adminRolesRoute } from "./admin-roles-route.js";
import { adminUsersRoute } from "./admin-users-route.js";
import { dashboardRoute } from "./dashboard-route.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { metricsRoute } from "./metrics-route.js";
import { sessionRoute } from "./session-route.js";
import { feedbackRoute } from "./feedback-route.js";

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

const getHealthPayload = () => ({
  ok: true,
  service: "2avendas-backend",
  timestamp: new Date().toISOString(),
});

app.get("/health", (c) => jsonOk(c, getHealthPayload()));

app.get("/", (c) =>
  jsonOk(c, {
    ok: true,
    service: "2avendas-backend",
    hint: "Dashboard executivo: GET /dashboard | KPIs: GET /metrics | Feedback: GET /feedback/messages (API key) | Menu: GET /api/session/menu (Bearer) | Saúde: GET /health",
  }),
);

app.route("/metrics", metricsRoute);
app.route("/feedback", feedbackRoute);
app.route("/dashboard", dashboardRoute);
app.route("/api/admin/roles", adminRolesRoute);
app.route("/api/admin/users", adminUsersRoute);
app.route("/api/session", sessionRoute);

app.notFound((c) => jsonFail(c, 404, "Rota não encontrada.", "NOT_FOUND"));

app.onError((err, c) => {
  console.error("Unhandled API error:", err instanceof Error ? err.message : String(err));
  return jsonFail(c, 500, "Erro interno.", "INTERNAL_ERROR");
});

const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`2avendas-backend listening on ${info.address}:${info.port}`);
});
