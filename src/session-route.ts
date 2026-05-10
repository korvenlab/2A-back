import { Hono } from "hono";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const ROLE_PRIORITY = ["admin", "vendedor", "cliente"] as const;

function roleRank(slug: string | null | undefined): number {
  const s = slug?.trim().toLowerCase() ?? "";
  const i = ROLE_PRIORITY.indexOf(s as (typeof ROLE_PRIORITY)[number]);
  return i === -1 ? 999 : i;
}

/** Mescla candidatos de app_users e user_roles — admin vence vendedor/cliente mesmo se app_users estiver defasado. */
function strongestRoleSlug(...candidates: (string | null | undefined)[]): string | null {
  let best: string | null = null;
  let bestR = 999;
  for (const c of candidates) {
    const s = c?.trim().toLowerCase() ?? "";
    if (!s) continue;
    const r = roleRank(s);
    if (r >= 999) continue;
    if (r < bestR) {
      bestR = r;
      best = s;
    }
  }
  return best;
}

/** Mapa estável para o frontend esconder itens de navegação (evita páginas que disparam erro de permissão Supabase). */
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

/** Catálogo administrativo (/catalogo): somente products:manage (admin/vendedor). Clientes usam apenas portal:view + products via portal. */
function buildMenu(permissions: Set<string>, roleSlug: string | null) {
  const slug = roleSlug?.trim().toLowerCase() ?? "";
  const isAdmin = slug === "admin";
  return {
    dashboard: permissions.has("dashboard:view"),
    catalogo: permissions.has("products:manage"),
    clientes: permissions.has("customers:view"),
    pedidos: permissions.has("orders:view"),
    /** Mesmo público de pedidos (admin / vendedor com orders:view). */
    orcamentos: permissions.has("orders:view"),
    /** CRM / funil — quem vê clientes gerencia oportunidades. */
    funil: permissions.has("customers:view"),
    /** Agenda de visitas — mesmo público do CRM. */
    visitas: permissions.has("customers:view"),
    portal: permissions.has("portal:view"),
    /** Admin sempre gerencia convites de vendedores e links; permissão sellers:view cobre matrizes customizadas. */
    vendedores: isAdmin || permissions.has("sellers:view"),
  };
}

function bearerToken(authHeader: string | undefined): string | null {
  const m = authHeader?.trim().match(/^Bearer\s+(.+)$/i);
  return m?.[1]?.trim() ?? null;
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

  const { data: authData, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !authData.user) {
    return jsonFail(c, 401, "Sessão inválida ou expirada.", "UNAUTHORIZED");
  }

  const userId = authData.user.id;

  const { data: auRow, error: auErr } = await supabaseAdmin
    .from("app_users")
    .select("role, organization_id, active")
    .eq("id", userId)
    .is("deleted_at", null)
    .maybeSingle();

  if (auErr) return jsonFail(c, 503, auErr.message, "UNAVAILABLE");

  let roleSlug: string | null = null;
  let organizationId: string | null = null;

  const au = auRow;

  if (au && au.active === false) {
    return jsonOk(c, {
      ok: true,
      data: {
        user_id: userId,
        organization_id: au.organization_id,
        role: au.role,
        active: false as const,
        permissions: [] as string[],
        menu: emptyMenu(),
      },
    });
  }

  if (au && au.active !== false) {
    organizationId = au.organization_id ?? null;
  }

  const { data: urRows, error: urErr } = await supabaseAdmin
    .from("user_roles")
    .select("role, organization_id")
    .eq("user_id", userId);

  if (urErr) return jsonFail(c, 503, urErr.message, "UNAVAILABLE");

  type Ur = { role: string | null; organization_id: string | null };
  const urList = (urRows ?? []) as Ur[];

  roleSlug = strongestRoleSlug(
    au?.role,
    ...urList.map((r) => r.role),
  );

  if (!roleSlug) {
    return jsonOk(c, {
      ok: true,
      data: {
        user_id: userId,
        organization_id: organizationId,
        role: null as string | null,
        permissions: [] as string[],
        menu: emptyMenu(),
      },
    });
  }

  if (!organizationId) {
    const matchOrg = urList.find(
      (r) => String(r.role ?? "").trim().toLowerCase() === roleSlug,
    );
    organizationId = matchOrg?.organization_id ?? urList[0]?.organization_id ?? null;
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
  const menu = buildMenu(new Set(permissions), roleSlug);

  return jsonOk(c, {
    ok: true,
    data: {
      user_id: userId,
      organization_id: organizationId,
      role: roleSlug,
      permissions,
      menu,
    },
  });
});
