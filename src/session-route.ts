import { Hono } from "hono";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

/** Mapa estável para o frontend esconder itens de navegação (evita páginas que disparam erro de permissão Supabase). */
function emptyMenu() {
  return {
    dashboard: false,
    catalogo: false,
    clientes: false,
    pedidos: false,
    portal: false,
    vendedores: false,
  };
}

function buildMenu(permissions: Set<string>) {
  return {
    dashboard: permissions.has("dashboard:view"),
    catalogo: permissions.has("products:view"),
    clientes: permissions.has("customers:view"),
    pedidos: permissions.has("orders:view"),
    portal: permissions.has("portal:view"),
    vendedores: permissions.has("sellers:view"),
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
    roleSlug = au.role?.trim().toLowerCase() || null;
    organizationId = au.organization_id ?? null;
  }

  if (!roleSlug) {
    const { data: urRow, error: urErr } = await supabaseAdmin
      .from("user_roles")
      .select("role, organization_id")
      .eq("user_id", userId)
      .maybeSingle();

    if (urErr) return jsonFail(c, 503, urErr.message, "UNAVAILABLE");

    if (!urRow?.role) {
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

    roleSlug = String(urRow.role).trim().toLowerCase();
    if (!organizationId) organizationId = urRow.organization_id ?? null;
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
  const menu = buildMenu(new Set(permissions));

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
