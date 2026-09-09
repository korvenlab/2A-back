import { Hono } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { resolveBearerSession } from "./bearer-session.js";
import { drainDashboardOutbox } from "./dashboard-publisher.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

function emptyMenu() {
  return {
    dashboard: false,
    catalogo: false,
    clientes: false,
    pedidos: false,
    orcamentos: false,
    funil: false,
    visitas: false,
    portal: false,
    vendedores: false,
  };
}

function buildMenu(permissions: Set<string>, roleSlug: string | null) {
  const slug = roleSlug?.trim().toLowerCase() ?? "";
  const isAdmin = slug === "admin";
  /** `orders:view` no cliente serve ao portal B2B (RLS); /pedidos e /orcamentos são só staff. */
  const staffOrdersScreens = permissions.has("orders:view") && slug !== "cliente";
  return {
    dashboard: permissions.has("dashboard:view"),
    catalogo: permissions.has("products:manage"),
    clientes: permissions.has("customers:view"),
    pedidos: staffOrdersScreens,
    orcamentos: staffOrdersScreens,
    funil: permissions.has("customers:view"),
    visitas: permissions.has("customers:view"),
    portal: permissions.has("portal:view"),
    vendedores: isAdmin || permissions.has("sellers:view"),
  };
}

function bearerToken(authHeader: string | undefined): string | null {
  const m = authHeader?.trim().match(/^Bearer\s+(.+)$/i);
  return m?.[1]?.trim() ?? null;
}

function staffNeedsBilling(roleSlug: string | null): boolean {
  const s = roleSlug?.trim().toLowerCase() ?? "";
  return s === "admin" || s === "vendedor";
}

/** Cortesia ainda válida (PostgREST pode devolver string ISO, Date em runtimes JS, ou epoch em edge cases). */
function complimentaryAccessIsActive(raw: unknown): boolean {
  if (raw == null) return false;
  let ms: number;
  if (typeof raw === "string") {
    const s = raw.trim();
    if (!s) return false;
    ms = Date.parse(s);
  } else if (typeof raw === "number" && Number.isFinite(raw)) {
    ms = raw < 1e12 ? raw * 1000 : raw;
  } else if (raw instanceof Date) {
    ms = raw.getTime();
  } else {
    return false;
  }
  return Number.isFinite(ms) && ms > Date.now();
}

export const sessionRoute = new Hono();

sessionRoute.get("/menu", async (c) => {
  const token = bearerToken(c.req.header("Authorization"));
  if (!token) {
    return jsonFail(
      c,
      401,
      "Autenticação necessária: envie Authorization: Bearer com access_token da sessão Supabase.",
      "UNAUTHORIZED",
    );
  }

  const resolved = await resolveBearerSession(token);
  if (!resolved.ok) {
    return jsonFail(c, resolved.status as ContentfulStatusCode, resolved.message, resolved.code);
  }

  const sessionOccurredAt = new Date().toISOString();
  const { error: sessionEventError } = await (supabaseAdmin as any).rpc("record_dashboard_session", {
    p_user_id: resolved.data.userId,
    p_organization_id: resolved.data.organizationId,
    p_email: resolved.data.email,
    p_occurred_at: sessionOccurredAt,
  });
  if (sessionEventError) {
    console.error("[session] dashboard event enqueue failed:", sessionEventError.message);
  } else {
    void drainDashboardOutbox();
  }

  const {
    userId,
    organizationId: org0,
    roleSlug: role0,
    inactive,
    inactiveAppRole,
    inactiveOrganizationId,
  } = resolved.data;

  if (inactive) {
    return jsonOk(c, {
      ok: true,
      data: {
        user_id: userId,
        organization_id: inactiveOrganizationId,
        role: inactiveAppRole,
        active: false as const,
        permissions: [] as string[],
        menu: emptyMenu(),
        billing: {
          required: false,
          satisfied: true,
          stripe_active: false,
          manual_unlock: false,
          user_stripe_paid: false,
        },
      },
    });
  }

  let organizationId = org0;
  let roleSlug = role0;

  if (!roleSlug) {
    return jsonOk(c, {
      ok: true,
      data: {
        user_id: userId,
        organization_id: organizationId,
        role: null as string | null,
        permissions: [] as string[],
        menu: emptyMenu(),
        billing: {
          required: false,
          satisfied: true,
          stripe_active: false,
          manual_unlock: false,
          user_stripe_paid: false,
        },
      },
    });
  }

  type PermRow = { permission: string };
  const permRes = await (supabaseAdmin as any)
    .from("app_role_permissions")
    .select("permission")
    .eq("role_slug", roleSlug);

  const permErr = permRes.error;
  const permData = permRes.data;
  if (permErr) return jsonFail(c, 503, permErr.message, "UNAVAILABLE");

  const permissionRows = (permData ?? []) as PermRow[];
  const permissions = permissionRows.map((r) => r.permission);
  let menu = buildMenu(new Set(permissions), roleSlug);

  let billingStripe = false;
  let billingManual = false;
  let userStripePaid = false;
  let userComplimentaryActive = false;
  /** Org para Stripe/unlock manual: app_users.organization_id tem prioridade sobre a resolvida no Bearer. */
  let responseOrganizationId = organizationId;

  if (staffNeedsBilling(roleSlug)) {
    const { data: auRow, error: auErr } = await supabaseAdmin
      .from("app_users")
      .select("organization_id, billing_stripe_access_at, billing_complimentary_access_until")
      .eq("id", userId)
      .maybeSingle();
    if (auErr) return jsonFail(c, 503, auErr.message, "UNAVAILABLE");
    const au = auRow as {
      organization_id?: string | null;
      billing_stripe_access_at?: string | null;
      billing_complimentary_access_until?: string | null;
    } | null;
    const billingOrgId = au?.organization_id ?? organizationId;
    responseOrganizationId = billingOrgId ?? organizationId;

    if (billingOrgId) {
      const { data: orgRow, error: orgErr } = await supabaseAdmin
        .from("organizations")
        .select("billing_stripe_active, billing_manual_unlock")
        .eq("id", billingOrgId)
        .maybeSingle();
      if (orgErr) return jsonFail(c, 503, orgErr.message, "UNAVAILABLE");
      const row = orgRow as {
        billing_stripe_active?: boolean | null;
        billing_manual_unlock?: boolean | null;
      } | null;
      billingStripe = !!row?.billing_stripe_active;
      billingManual = !!row?.billing_manual_unlock;
    }

    userStripePaid = !!au?.billing_stripe_access_at;
    userComplimentaryActive = complimentaryAccessIsActive(au?.billing_complimentary_access_until);

    const satisfied = billingStripe || billingManual || userStripePaid || userComplimentaryActive;
    if (!satisfied && billingOrgId) {
      menu = emptyMenu();
    }
  }

  const billingRequired = staffNeedsBilling(roleSlug) && !!responseOrganizationId;
  const billingSatisfied =
    !billingRequired ||
    billingStripe ||
    billingManual ||
    userStripePaid ||
    userComplimentaryActive;

  return jsonOk(c, {
    ok: true,
    data: {
      user_id: userId,
      organization_id: responseOrganizationId,
      role: roleSlug,
      permissions,
      menu,
      billing: {
        required: billingRequired,
        satisfied: billingSatisfied,
        stripe_active: billingStripe,
        manual_unlock: billingManual,
        user_stripe_paid: userStripePaid,
        user_complimentary_active: userComplimentaryActive,
      },
    },
  });
});
