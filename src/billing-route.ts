import { randomBytes } from "node:crypto";
import { Hono } from "hono";
import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import Stripe from "stripe";
import { mintBillingUnlockToken, verifyBillingUnlockToken } from "./billing-unlock-token.js";
import { resolveBearerSession } from "./bearer-session.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

function bearerToken(authHeader: string | undefined): string | null {
  const m = authHeader?.trim().match(/^Bearer\s+(.+)$/i);
  return m?.[1]?.trim() ?? null;
}

function stripeClient(): Stripe | null {
  const key = process.env.STRIPE_SECRET_KEY?.trim();
  if (!key) return null;
  return new Stripe(key);
}

/**
 * URL base do app em links enviados ao utilizador (cortesia, unlock, redirects Stripe).
 * Use `PUBLIC_APP_ORIGIN` quando `FRONTEND_ORIGIN` tiver várias origens (CORS) e a primeira
 * for a preview Vercel — assim os links podem ser sempre https://2avendas.com.
 */
function checkoutOrigin(): string {
  const explicit = process.env.PUBLIC_APP_ORIGIN?.trim();
  if (explicit && explicit !== "*") {
    const one = explicit.split(",")[0]?.trim().replace(/\/+$/, "") ?? "";
    if (one) return one;
  }
  const raw = process.env.FRONTEND_ORIGIN?.trim();
  if (!raw || raw === "*") return "http://localhost:5173";
  const first = raw.split(",")[0]?.trim().replace(/\/+$/, "") ?? "";
  return first || "http://localhost:5173";
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(s: string): boolean {
  return UUID_RE.test(s.trim());
}

export const billingRoute = new Hono();

/**
 * Korven Dashboard (API server-to-server): aplica `billing_manual_unlock` direto.
 * Para **liberar** com fluxo tipo Wagoo (link copiável), prefira `POST /organization-access-link`.
 * `unlock: false` continua útil para revogar sem link.
 */
billingRoute.post("/organization-access", async (c) => {
  const secret = process.env.KORVEN_BILLING_ADMIN_SECRET?.trim();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (c.req.header("X-Billing-Admin-Secret") !== secret) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  let body: { organization_id?: string; unlock?: boolean };
  try {
    body = (await c.req.json()) as { organization_id?: string; unlock?: boolean };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  const organizationId = typeof body.organization_id === "string" ? body.organization_id.trim() : "";
  if (!organizationId) {
    return jsonFail(c, 400, "organization_id é obrigatório.", "BAD_REQUEST");
  }

  const unlock = body.unlock === true;

  const { error } = await supabaseAdmin
    .from("organizations")
    .update({ billing_manual_unlock: unlock })
    .eq("id", organizationId);

  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");

  return jsonOk(c, { ok: true as const, organization_id: organizationId, billing_manual_unlock: unlock });
});

/** Korven Dashboard: gera URL pública (como /wagoo) para o cliente abrir e liberar a organização. */
billingRoute.post("/organization-access-link", async (c) => {
  const secret = process.env.KORVEN_BILLING_ADMIN_SECRET?.trim();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (c.req.header("X-Billing-Admin-Secret") !== secret) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  let body: { organization_id?: string; ttl_seconds?: number };
  try {
    body = (await c.req.json()) as { organization_id?: string; ttl_seconds?: number };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  const organizationId = typeof body.organization_id === "string" ? body.organization_id.trim() : "";
  if (!organizationId) {
    return jsonFail(c, 400, "organization_id é obrigatório.", "BAD_REQUEST");
  }

  const { data: row, error: findErr } = await supabaseAdmin
    .from("organizations")
    .select("id")
    .eq("id", organizationId)
    .maybeSingle();

  if (findErr) return jsonFail(c, 503, findErr.message, "UNAVAILABLE");
  if (!row) {
    return jsonFail(c, 404, "Organização não encontrada.", "NOT_FOUND");
  }

  const ttl =
    typeof body.ttl_seconds === "number" && Number.isFinite(body.ttl_seconds)
      ? Math.floor(body.ttl_seconds)
      : undefined;

  const minted = mintBillingUnlockToken(organizationId, ttl);
  if (!minted) {
    return jsonFail(c, 503, "Não foi possível assinar o link.", "UNAVAILABLE");
  }

  const front = checkoutOrigin();
  const unlockUrl = `${front}/billing/unlock?t=${encodeURIComponent(minted.token)}`;

  return jsonOk(c, {
    ok: true as const,
    data: {
      unlock_url: unlockUrl,
      expires_at: minted.expires_at,
      organization_id: organizationId,
    },
  });
});

/** Público: consome o token do link e define `billing_manual_unlock` na organização. */
billingRoute.post("/claim-unlock", async (c) => {
  let body: { token?: string };
  try {
    body = (await c.req.json()) as { token?: string };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  const rawToken = typeof body.token === "string" ? body.token.trim() : "";
  if (!rawToken) {
    return jsonFail(c, 400, "token é obrigatório.", "BAD_REQUEST");
  }

  const verified = verifyBillingUnlockToken(rawToken);
  if (!verified) {
    return jsonFail(c, 400, "Link inválido ou expirado.", "BAD_REQUEST");
  }

  const { data: orgRow, error: findErr } = await supabaseAdmin
    .from("organizations")
    .select("id")
    .eq("id", verified.organizationId)
    .maybeSingle();

  if (findErr) return jsonFail(c, 503, findErr.message, "UNAVAILABLE");
  if (!orgRow) {
    return jsonFail(c, 404, "Organização não encontrada.", "NOT_FOUND");
  }

  const { error } = await supabaseAdmin
    .from("organizations")
    .update({ billing_manual_unlock: true })
    .eq("id", verified.organizationId);

  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");

  return jsonOk(c, { ok: true as const, organization_id: verified.organizationId });
});

function korvenBillingSecret(): string | null {
  return process.env.KORVEN_BILLING_ADMIN_SECRET?.trim() ?? null;
}

function assertBillingAdmin(c: Context): boolean {
  const secret = korvenBillingSecret();
  if (!secret) return false;
  return c.req.header("X-Billing-Admin-Secret") === secret;
}

function randomPromoCode(): string {
  return randomBytes(8).toString("hex").slice(0, 12).toLowerCase();
}

function signupPromoUrl(code: string): string {
  const front = checkoutOrigin();
  return `${front}/login?two_avendas_promo=${encodeURIComponent(code)}`;
}

type PromoLinkRow = {
  id: string;
  code: string;
  label: string | null;
  complimentary_days: number;
  max_redemptions: number | null;
  redemption_count: number;
  is_active: boolean;
  created_at: string;
};

function mapPromoRow(row: PromoLinkRow) {
  return {
    id: row.id,
    code: row.code,
    label: row.label,
    complimentary_days: row.complimentary_days,
    max_redemptions: row.max_redemptions,
    redemption_count: row.redemption_count,
    expires_at: null as string | null,
    is_active: row.is_active,
    created_at: row.created_at,
    signup_url: signupPromoUrl(row.code),
  };
}

billingRoute.get("/promo-links", async (c) => {
  const secret = korvenBillingSecret();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (!assertBillingAdmin(c)) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  const { data, error } = await supabaseAdmin
    .from("billing_promo_links")
    .select("id, code, label, complimentary_days, max_redemptions, redemption_count, is_active, created_at")
    .order("created_at", { ascending: false });

  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");
  const items = (data ?? []).map((r) => mapPromoRow(r as PromoLinkRow));
  return jsonOk(c, { ok: true as const, data: { items } });
});

billingRoute.post("/promo-links", async (c) => {
  const secret = korvenBillingSecret();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (!assertBillingAdmin(c)) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  let body: {
    label?: string | null;
    complimentary_days?: number;
    max_redemptions?: number | null;
  };
  try {
    body = (await c.req.json()) as {
      label?: string | null;
      complimentary_days?: number;
      max_redemptions?: number | null;
    };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  const rawDays =
    typeof body.complimentary_days === "number" && Number.isFinite(body.complimentary_days)
      ? Math.floor(body.complimentary_days)
      : 60;
  const days = Math.min(730, Math.max(1, rawDays));

  let maxRed: number | null = null;
  if (body.max_redemptions !== undefined && body.max_redemptions !== null) {
    const n = Math.floor(Number(body.max_redemptions));
    if (!Number.isFinite(n) || n < 1) {
      return jsonFail(c, 400, "max_redemptions inválido.", "BAD_REQUEST");
    }
    maxRed = n;
  }

  const label =
    typeof body.label === "string" && body.label.trim() ? body.label.trim().slice(0, 200) : null;

  let inserted: PromoLinkRow | null = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    const code = randomPromoCode();
    const { data, error } = await supabaseAdmin
      .from("billing_promo_links")
      .insert({
        code,
        label,
        complimentary_days: days,
        max_redemptions: maxRed,
        redemption_count: 0,
        is_active: true,
      })
      .select("id, code, label, complimentary_days, max_redemptions, redemption_count, is_active, created_at")
      .maybeSingle();

    if (!error && data) {
      inserted = data as PromoLinkRow;
      break;
    }
    if (error && error.code !== "23505") {
      return jsonFail(c, 503, error.message, "UNAVAILABLE");
    }
  }

  if (!inserted) {
    return jsonFail(c, 503, "Não foi possível gerar código único.", "UNAVAILABLE");
  }

  return jsonOk(c, { ok: true as const, data: mapPromoRow(inserted) });
});

billingRoute.patch("/promo-links/:id", async (c) => {
  const secret = korvenBillingSecret();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (!assertBillingAdmin(c)) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  const id = c.req.param("id")?.trim() ?? "";
  if (!isUuid(id)) {
    return jsonFail(c, 400, "id inválido.", "BAD_REQUEST");
  }

  let body: { is_active?: boolean };
  try {
    body = (await c.req.json()) as { is_active?: boolean };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  if (typeof body.is_active !== "boolean") {
    return jsonFail(c, 400, "is_active (boolean) é obrigatório.", "BAD_REQUEST");
  }

  const { data, error } = await supabaseAdmin
    .from("billing_promo_links")
    .update({ is_active: body.is_active })
    .eq("id", id)
    .select("id, code, label, complimentary_days, max_redemptions, redemption_count, is_active, created_at")
    .maybeSingle();

  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");
  if (!data) {
    return jsonFail(c, 404, "Link não encontrado.", "NOT_FOUND");
  }

  return jsonOk(c, { ok: true as const, data: mapPromoRow(data as PromoLinkRow) });
});

billingRoute.delete("/promo-links/:id", async (c) => {
  const secret = korvenBillingSecret();
  if (!secret) {
    return jsonFail(c, 503, "Unlock administrativo não configurado.", "UNAVAILABLE");
  }
  if (!assertBillingAdmin(c)) {
    return jsonFail(c, 401, "Credencial administrativa inválida.", "UNAUTHORIZED");
  }

  const id = c.req.param("id")?.trim() ?? "";
  if (!isUuid(id)) {
    return jsonFail(c, 400, "id inválido.", "BAD_REQUEST");
  }

  const { error } = await supabaseAdmin.from("billing_promo_links").delete().eq("id", id);
  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");

  return jsonOk(c, { ok: true as const, data: { id, deleted: true } });
});

function staffMayRedeemPromo(roleSlug: string | null): boolean {
  const s = roleSlug?.trim().toLowerCase() ?? "";
  return s === "admin" || s === "vendedor";
}

/** Autenticado (Bearer): resgata código visto em `?two_avendas_promo=` no login. */
billingRoute.post("/redeem-promo", async (c) => {
  const token = bearerToken(c.req.header("Authorization"));
  if (!token) {
    return jsonFail(c, 401, "Autenticação necessária (Bearer).", "UNAUTHORIZED");
  }

  const resolved = await resolveBearerSession(token);
  if (!resolved.ok) {
    return jsonFail(c, resolved.status as ContentfulStatusCode, resolved.message, resolved.code);
  }
  if (resolved.data.inactive) {
    return jsonFail(c, 403, "Conta inativa.", "FORBIDDEN");
  }

  const { userId, organizationId, roleSlug } = resolved.data;
  if (!staffMayRedeemPromo(roleSlug)) {
    return jsonFail(
      c,
      403,
      "Apenas administrador ou vendedor pode resgatar o código promocional.",
      "FORBIDDEN",
    );
  }
  if (!organizationId) {
    return jsonFail(c, 400, "Sem organização ativa.", "BAD_REQUEST");
  }

  let body: { code?: string };
  try {
    body = (await c.req.json()) as { code?: string };
  } catch {
    return jsonFail(c, 400, "JSON inválido.", "BAD_REQUEST");
  }

  const rawCode = typeof body.code === "string" ? body.code.trim() : "";
  if (!rawCode) {
    return jsonFail(c, 400, "code é obrigatório.", "BAD_REQUEST");
  }

  const { data: rpcData, error: rpcErr } = await supabaseAdmin.rpc("redeem_billing_promo_link", {
    p_code: rawCode,
    p_user_id: userId,
    p_org_id: organizationId,
  });

  if (rpcErr) {
    return jsonFail(c, 503, rpcErr.message, "UNAVAILABLE");
  }

  const root = rpcData as { ok?: boolean; error?: string; complimentary_until?: string };
  if (!root?.ok) {
    return jsonFail(c, 400, root?.error ?? "Resgate não permitido.", "BAD_REQUEST");
  }

  return jsonOk(c, {
    ok: true as const,
    data: { complimentary_until: root.complimentary_until ?? null },
  });
});

billingRoute.post("/checkout-session", async (c) => {
  const stripe = stripeClient();
  const priceId = process.env.STRIPE_PRICE_ID?.trim();
  if (!stripe || !priceId) {
    return jsonFail(c, 503, "Cobrança Stripe não configurada no servidor.", "UNAVAILABLE");
  }

  const token = bearerToken(c.req.header("Authorization"));
  if (!token) {
    return jsonFail(c, 401, "Autenticação necessária (Bearer).", "UNAUTHORIZED");
  }

  const resolved = await resolveBearerSession(token);
  if (!resolved.ok) {
    return jsonFail(c, resolved.status as ContentfulStatusCode, resolved.message, resolved.code);
  }
  if (resolved.data.inactive) {
    return jsonFail(c, 403, "Conta inativa.", "FORBIDDEN");
  }

  const { userId, email, organizationId, roleSlug } = resolved.data;
  if (roleSlug?.trim().toLowerCase() !== "admin") {
    return jsonFail(c, 403, "Apenas o administrador da representação pode iniciar o pagamento.", "FORBIDDEN");
  }
  if (!organizationId) {
    return jsonFail(c, 400, "Organização não encontrada para o usuário.", "BAD_REQUEST");
  }

  const { data: org, error: orgErr } = await supabaseAdmin
    .from("organizations")
    .select("stripe_customer_id, billing_stripe_active, billing_manual_unlock")
    .eq("id", organizationId)
    .maybeSingle();

  if (orgErr) return jsonFail(c, 503, orgErr.message, "UNAVAILABLE");
  const orgRow = org as {
    stripe_customer_id?: string | null;
    billing_stripe_active?: boolean | null;
    billing_manual_unlock?: boolean | null;
  } | null;

  if (orgRow?.billing_stripe_active || orgRow?.billing_manual_unlock) {
    return jsonFail(c, 409, "Esta organização já tem acesso liberado.", "CONFLICT");
  }

  const { data: auPay, error: auPayErr } = await supabaseAdmin
    .from("app_users")
    .select("billing_stripe_access_at")
    .eq("id", userId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (auPayErr) return jsonFail(c, 503, auPayErr.message, "UNAVAILABLE");
  const auPayRow = auPay as { billing_stripe_access_at?: string | null } | null;
  if (auPayRow?.billing_stripe_access_at) {
    return jsonFail(c, 409, "Este usuário já possui acesso pago via Stripe.", "CONFLICT");
  }

  const origin = checkoutOrigin();
  const successUrl = `${origin}/assinatura?checkout=success`;
  const cancelUrl = `${origin}/assinatura?checkout=cancel`;

  const customerId =
    typeof orgRow?.stripe_customer_id === "string" && orgRow.stripe_customer_id.startsWith("cus_")
      ? orgRow.stripe_customer_id
      : undefined;

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: `${organizationId}:${userId}`,
    metadata: {
      organization_id: organizationId,
      payer_user_id: userId,
    },
    subscription_data: {
      metadata: {
        organization_id: organizationId,
      },
    },
    ...(customerId
      ? { customer: customerId }
      : email
        ? { customer_email: email }
        : {}),
  });

  if (!session.url) {
    return jsonFail(c, 503, "Stripe não retornou URL de checkout.", "UNAVAILABLE");
  }

  return jsonOk(c, { url: session.url });
});

billingRoute.post("/webhook", async (c) => {
  const stripe = stripeClient();
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET?.trim();
  if (!stripe || !webhookSecret) {
    return jsonFail(c, 503, "Webhook Stripe não configurado.", "UNAVAILABLE");
  }

  const signature = c.req.header("stripe-signature");
  if (!signature) {
    return jsonFail(c, 400, "Cabeçalho Stripe-Signature ausente.", "BAD_REQUEST");
  }

  const rawBody = await c.req.text();

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return jsonFail(c, 400, `Webhook inválido: ${msg}`, "BAD_REQUEST");
  }

  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const session = event.data.object as Stripe.Checkout.Session;
        const cref =
          typeof session.client_reference_id === "string" ? session.client_reference_id.trim() : "";
        const metaOrgRaw =
          typeof session.metadata?.organization_id === "string"
            ? session.metadata.organization_id.trim()
            : "";
        const metaPayerRaw =
          typeof session.metadata?.payer_user_id === "string"
            ? session.metadata.payer_user_id.trim()
            : typeof session.metadata?.user_id === "string"
              ? session.metadata.user_id.trim()
              : "";

        let orgId: string | null = null;
        let payerUserId: string | null = null;

        if (cref.includes(":")) {
          const [a, b, ...rest] = cref.split(":");
          if (rest.length === 0 && isUuid(a) && isUuid(b)) {
            orgId = a;
            payerUserId = b;
          }
        } else if (cref && isUuid(cref)) {
          orgId = cref;
        }
        if (!orgId && metaOrgRaw && isUuid(metaOrgRaw)) {
          orgId = metaOrgRaw;
        }
        if (!payerUserId && metaPayerRaw && isUuid(metaPayerRaw)) {
          payerUserId = metaPayerRaw;
        }

        if (!orgId || !isUuid(orgId)) break;

        const customerId =
          typeof session.customer === "string"
            ? session.customer
            : session.customer && typeof session.customer === "object" && "id" in session.customer
              ? (session.customer as { id: string }).id
              : null;
        const subId =
          typeof session.subscription === "string"
            ? session.subscription
            : session.subscription && typeof session.subscription === "object" && "id" in session.subscription
              ? (session.subscription as Stripe.Subscription).id
              : null;

        const now = new Date().toISOString();

        if (payerUserId && isUuid(payerUserId)) {
          const { error: auErr } = await supabaseAdmin
            .from("app_users")
            .update({ billing_stripe_access_at: now })
            .eq("id", payerUserId)
            .eq("organization_id", orgId);
          if (auErr) throw new Error(auErr.message);

          const orgPatch: { stripe_customer_id?: string; stripe_subscription_id?: string | null } = {};
          if (customerId) orgPatch.stripe_customer_id = customerId;
          if (subId !== null && subId !== undefined) orgPatch.stripe_subscription_id = subId;
          if (Object.keys(orgPatch).length > 0) {
            const { error: orgUpErr } = await supabaseAdmin.from("organizations").update(orgPatch).eq("id", orgId);
            if (orgUpErr) throw new Error(orgUpErr.message);
          }
        } else {
          const patch: {
            billing_stripe_active: boolean;
            stripe_customer_id?: string;
            stripe_subscription_id?: string | null;
          } = { billing_stripe_active: true };
          if (customerId) patch.stripe_customer_id = customerId;
          if (subId !== null && subId !== undefined) patch.stripe_subscription_id = subId;
          const { error: orgErr2 } = await supabaseAdmin.from("organizations").update(patch).eq("id", orgId);
          if (orgErr2) throw new Error(orgErr2.message);
        }
        break;
      }
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        const orgIdMeta = sub.metadata?.organization_id;
        const active = sub.status === "active" || sub.status === "trialing";
        if (orgIdMeta) {
          await supabaseAdmin
            .from("organizations")
            .update({
              stripe_subscription_id: sub.id,
              billing_stripe_active: active,
            })
            .eq("id", orgIdMeta);
        } else {
          await supabaseAdmin
            .from("organizations")
            .update({
              stripe_subscription_id: sub.id,
              billing_stripe_active: active,
            })
            .eq("stripe_subscription_id", sub.id);
        }
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        await supabaseAdmin
          .from("organizations")
          .update({
            billing_stripe_active: false,
            stripe_subscription_id: null,
          })
          .eq("stripe_subscription_id", sub.id);
        break;
      }
      default:
        break;
    }
  } catch (e) {
    console.error("[billing webhook] handler error:", e instanceof Error ? e.message : String(e));
    return jsonFail(c, 500, "Erro ao aplicar evento.", "INTERNAL_ERROR");
  }

  return jsonOk(c, { received: true });
});
