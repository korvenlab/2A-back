import { Hono } from "hono";
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

function checkoutOrigin(): string {
  const raw = process.env.FRONTEND_ORIGIN?.trim();
  if (!raw || raw === "*") return "http://localhost:5173";
  const first = raw.split(",")[0]?.trim();
  return first?.replace(/\/+$/, "") || "http://localhost:5173";
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

  return jsonOk(c, { organization_id: organizationId, billing_manual_unlock: unlock });
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
    unlock_url: unlockUrl,
    expires_at: minted.expires_at,
    organization_id: organizationId,
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

  return jsonOk(c, { organization_id: verified.organizationId });
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
    client_reference_id: organizationId,
    metadata: {
      organization_id: organizationId,
      user_id: userId,
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
        const rawOrg =
          typeof session.metadata?.organization_id === "string"
            ? session.metadata.organization_id
            : typeof session.client_reference_id === "string"
              ? session.client_reference_id
              : undefined;
        const orgId = rawOrg?.trim();
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

        const patch: {
          billing_stripe_active: boolean;
          stripe_customer_id?: string;
          stripe_subscription_id?: string | null;
        } = { billing_stripe_active: true };
        if (customerId) patch.stripe_customer_id = customerId;
        if (subId !== null && subId !== undefined) patch.stripe_subscription_id = subId;

        await supabaseAdmin.from("organizations").update(patch).eq("id", orgId);
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
