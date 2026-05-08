import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LEGACY_RBAC_ROLES = new Set(["admin", "vendedor", "cliente"]);
type LegacyRbacRole = "admin" | "vendedor" | "cliente";

interface AppUserRow {
  id: string;
  email: string | null;
  name: string | null;
  role: string;
  active: boolean;
  last_sign_in_at: string | null;
  created_at: string;
  organization_id: string | null;
}

interface UserShape {
  id: string;
  email: string | null;
  name: string | null;
  role: string;
  active: boolean;
  createdAt: string;
  lastSignInAt: string | null;
}

function parsePagination(
  pageRaw: string | undefined,
  limitRaw: string | undefined,
): { ok: true; page: number; limit: number } | { ok: false; message: string } {
  const page = pageRaw ? Number.parseInt(pageRaw, 10) : 1;
  const limit = limitRaw ? Number.parseInt(limitRaw, 10) : 20;
  if (!Number.isFinite(page) || page < 1) return { ok: false, message: "page deve ser inteiro >= 1." };
  if (!Number.isFinite(limit) || limit < 1 || limit > 100) {
    return { ok: false, message: "limit deve ser inteiro entre 1 e 100." };
  }
  return { ok: true, page, limit };
}

function isRoleValueValid(value: string): boolean {
  return LEGACY_RBAC_ROLES.has(value);
}

function asLegacyRbacRole(value: string): LegacyRbacRole | null {
  if (!LEGACY_RBAC_ROLES.has(value)) return null;
  return value as LegacyRbacRole;
}

export const adminUsersRoute = new Hono();

adminUsersRoute.use("*", async (c, next) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;
  return next();
});

adminUsersRoute.get("/", async (c) => {
  const pg = parsePagination(c.req.query("page"), c.req.query("limit"));
  if (!pg.ok) return jsonFail(c, 400, pg.message, "VALIDATION_ERROR");
  const { page, limit } = pg;
  const search = c.req.query("search")?.trim();
  const from = (page - 1) * limit;
  const to = from + limit - 1;

  let query = supabaseAdmin
    .from("app_users")
    .select("id,email,name,role,active,last_sign_in_at,created_at,organization_id", { count: "exact" })
    .is("deleted_at", null)
    .order("created_at", { ascending: false });
  if (search && search.length > 0) {
    const s = search.replace(/[%_]/g, "");
    query = query.or(`email.ilike.%${s}%,name.ilike.%${s}%`);
  }
  const { data: users, error: usrErr, count } = await query.range(from, to);
  if (usrErr) return jsonFail(c, 503, usrErr.message, "UNAVAILABLE");

  const rows = (users ?? []) as AppUserRow[];

  const items: UserShape[] = rows.map((p) => {
    return {
      id: p.id,
      email: p.email ?? null,
      name: p.name,
      role: p.role || "cliente",
      active: p.active,
      createdAt: p.created_at,
      lastSignInAt: p.last_sign_in_at ?? null,
    };
  });

  return jsonOk(c, {
    ok: true,
    data: { items, page, limit, total: count ?? 0 },
  });
});

adminUsersRoute.get("/:id", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const { data: userRow, error: uErr } = await supabaseAdmin
    .from("app_users")
    .select("id,email,name,role,active,last_sign_in_at,created_at,organization_id")
    .eq("id", id)
    .is("deleted_at", null)
    .maybeSingle();
  if (uErr) return jsonFail(c, 503, uErr.message, "UNAVAILABLE");
  if (!userRow) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const user: UserShape = {
    id: userRow.id,
    email: userRow.email ?? null,
    name: userRow.name,
    role: userRow.role || "cliente",
    active: userRow.active,
    createdAt: userRow.created_at,
    lastSignInAt: userRow.last_sign_in_at ?? null,
  };
  return jsonOk(c, { ok: true, data: user });
});

adminUsersRoute.patch("/:id/role", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const body = await c.req.json().catch(() => null);
  const role = (body as { role?: string } | null)?.role?.trim().toLowerCase();
  if (!role) return jsonFail(c, 400, "Body inválido: role é obrigatória.", "VALIDATION_ERROR");
  if (!isRoleValueValid(role)) {
    return jsonFail(
      c,
      400,
      "role inválida. Use apenas: admin, vendedor ou cliente.",
      "VALIDATION_ERROR",
    );
  }

  const { data: user, error: uErr } = await supabaseAdmin
    .from("app_users")
    .select("id,organization_id")
    .eq("id", id)
    .is("deleted_at", null)
    .maybeSingle();
  if (uErr) return jsonFail(c, 503, uErr.message, "UNAVAILABLE");
  if (!user) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const organizationId = (user as { organization_id: string | null }).organization_id ?? null;
  const up = await supabaseAdmin
    .from("app_users")
    .update({ role, updated_at: new Date().toISOString() })
    .eq("id", id);
  if (up.error) return jsonFail(c, 503, up.error.message, "UNAVAILABLE");

  let syncedToUserRoles = false;
  const legacyRole = asLegacyRbacRole(role);
  if (legacyRole) {
    // Keep a single authoritative role per user across app contexts.
    const del = await supabaseAdmin.from("user_roles").delete().eq("user_id", id);
    if (del.error) return jsonFail(c, 503, del.error.message, "UNAVAILABLE");

    const ins = await supabaseAdmin
      .from("user_roles")
      .insert({ user_id: id, organization_id: organizationId, role: legacyRole });
    if (ins.error) return jsonFail(c, 503, ins.error.message, "UNAVAILABLE");
    syncedToUserRoles = true;
  }

  return jsonOk(c, { ok: true, data: { id, role, syncedToUserRoles } });
});

adminUsersRoute.patch("/:id/status", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const body = await c.req.json().catch(() => null);
  const active = (body as { active?: unknown } | null)?.active;
  if (typeof active !== "boolean") {
    return jsonFail(c, 400, "Body inválido: active (boolean) é obrigatório.", "VALIDATION_ERROR");
  }

  const patch = active ? { active: true, deleted_at: null } : { active: false, deleted_at: new Date().toISOString() };
  const { data, error } = await supabaseAdmin
    .from("app_users")
    .update(patch)
    .eq("id", id)
    .select("id,active,deleted_at")
    .maybeSingle();
  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");
  if (!data) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  return jsonOk(c, {
    ok: true,
    data: { id: (data as { id: string }).id, active: (data as { active: boolean }).active },
  });
});

adminUsersRoute.delete("/:id", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const { data, error } = await supabaseAdmin
    .from("app_users")
    .update({ active: false, deleted_at: new Date().toISOString() })
    .eq("id", id)
    .select("id,active,deleted_at")
    .maybeSingle();
  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");
  if (!data) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  return jsonOk(c, {
    ok: true,
    data: { id: (data as { id: string }).id, deleted: true },
  });
});

adminUsersRoute.get("/:id/assets", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const { data: profile, error: pErr } = await supabaseAdmin
    .from("app_users")
    .select("id,organization_id")
    .eq("id", id)
    .is("deleted_at", null)
    .maybeSingle();
  if (pErr) return jsonFail(c, 503, pErr.message, "UNAVAILABLE");
  if (!profile) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const orgId = (profile as { organization_id: string | null }).organization_id;
  const prefixes = [`users/${id}/`];
  if (orgId) prefixes.push(`org/${orgId}/users/${id}/`);

  const items: Array<{ bucket: string; path: string; name: string; updatedAt: string | null; size: number | null }> = [];
  for (const prefix of prefixes) {
    const { data, error } = await supabaseAdmin.storage.from("product-images").list(prefix, { limit: 200 });
    if (error) continue;
    for (const f of data ?? []) {
      const fo = f as { name: string; updated_at?: string | null; metadata?: { size?: number } };
      items.push({
        bucket: "product-images",
        path: `${prefix}${fo.name}`,
        name: fo.name,
        updatedAt: fo.updated_at ?? null,
        size: fo.metadata?.size ?? null,
      });
    }
  }

  return jsonOk(c, { ok: true, data: { items } });
});

