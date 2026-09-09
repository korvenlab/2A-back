import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { adminRolesRoute } from "./admin-roles-route.js";
import { adminUsersRoute } from "./admin-users-route.js";
import { dashboardRoute } from "./dashboard-route.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { metricsRoute } from "./metrics-route.js";
import { sessionRoute } from "./session-route.js";
import { feedbackRoute } from "./feedback-route.js";
import { billingRoute } from "./billing-route.js";
import { startDashboardOutboxWorker } from "./dashboard-publisher.js";

const app = new Hono();

app.use(
  "*",
  secureHeaders({
    xFrameOptions: "DENY",
    xContentTypeOptions: "nosniff",
    referrerPolicy: "strict-origin-when-cross-origin",
    permissionsPolicy: {
      camera: ["none"],
      microphone: ["none"],
      geolocation: ["none"],
      payment: ["none"],
      usb: ["none"],
    },
  }),
);

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
    allowHeaders: [
      "Content-Type",
      "Authorization",
      "X-API-Key",
      "x-admin-secret",
      "X-Billing-Admin-Secret",
      "Stripe-Signature",
      "Idempotency-Key",
    ],
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
    hint: "Dashboard executivo: GET /dashboard | KPIs: GET /metrics | Feedback: GET/DELETE /feedback/messages (API key) | Menu: GET /api/session/menu (Bearer) | Billing: checkout POST /api/billing/checkout-session (Bearer admin), webhook POST /api/billing/webhook (Stripe), Korven link POST /api/billing/organization-access-link (X-Billing-Admin-Secret), claim POST /api/billing/claim-unlock, cortesia GET/POST/PATCH/DELETE /api/billing/promo-links (admin), resgate POST /api/billing/redeem-promo (Bearer) | Saúde: GET /health",
  }),
);

app.route("/metrics", metricsRoute);
app.route("/feedback", feedbackRoute);
app.route("/dashboard", dashboardRoute);
app.route("/api/admin/roles", adminRolesRoute);
app.route("/api/admin/users", adminUsersRoute);
app.route("/api/session", sessionRoute);
app.route("/api/billing", billingRoute);

app.notFound((c) => jsonFail(c, 404, "Rota não encontrada.", "NOT_FOUND"));

app.onError((err, c) => {
  console.error("Unhandled API error:", err instanceof Error ? err.message : String(err));
  return jsonFail(c, 500, "Erro interno.", "INTERNAL_ERROR");
});

const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`2avendas-backend listening on ${info.address}:${info.port}`);
  startDashboardOutboxWorker();
});
