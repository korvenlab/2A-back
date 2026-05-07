import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const APP_ROLES = ["admin", "vendedor", "cliente"] as const;
type AppRole = (typeof APP_ROLES)[number];

interface ProfileRow {
  id: string;
  email: string | null;
  full_name: string | null;
  created_at: string;
  organization_id: string | null;
  active: boolean;
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

function isRole(value: string): value is AppRole {
  return APP_ROLES.includes(value as AppRole);
}

function pickPrimaryRole(
  rolesByUser: Map<string, Array<{ role: string; created_at?: string }>>,
  userId: string,
): string {
  const list = rolesByUser.get(userId) ?? [];
  if (list.length === 0) return "cliente";
  const priority = ["admin", "vendedor", "cliente"];
  for (const p of priority) {
    if (list.some((r) => r.role === p)) return p;
  }
  return list[0]?.role ?? "cliente";
}

async function getLastSignInMap(userIds: string[]): Promise<Map<string, { email: string | null; last: string | null }>> {
  const out = new Map<string, { email: string | null; last: string | null }>();
  await Promise.all(
    userIds.map(async (id) => {
      const { data, error } = await supabaseAdmin.auth.admin.getUserById(id);
      if (!error && data?.user) {
        out.set(id, { email: data.user.email ?? null, last: data.user.last_sign_in_at ?? null });
      }
    }),
  );
  return out;
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
    .from("profiles")
    .select("id,email,full_name,created_at,organization_id,active", { count: "exact" })
    .is("deleted_at", null)
    .order("created_at", { ascending: false });
  if (search && search.length > 0) {
    const s = search.replace(/[%_]/g, "");
    query = query.or(`email.ilike.%${s}%,full_name.ilike.%${s}%`);
  }
  const { data: profiles, error: profErr, count } = await query.range(from, to);
  if (profErr) return jsonFail(c, 503, profErr.message, "UNAVAILABLE");

  const rows = (profiles ?? []) as ProfileRow[];
  const userIds = rows.map((r) => r.id);

  const [rolesRes, signInMap] = await Promise.all([
    userIds.length
      ? supabaseAdmin
          .from("user_roles")
          .select("user_id,role,created_at")
          .in("user_id", userIds)
      : Promise.resolve({ data: [], error: null } as { data: never[]; error: null }),
    getLastSignInMap(userIds),
  ]);
  if (rolesRes.error) return jsonFail(c, 503, rolesRes.error.message, "UNAVAILABLE");

  const rolesByUser = new Map<string, Array<{ role: string; created_at?: string }>>();
  for (const row of rolesRes.data ?? []) {
    const r = row as { user_id: string; role: string; created_at?: string };
    const list = rolesByUser.get(r.user_id) ?? [];
    list.push({ role: r.role, created_at: r.created_at });
    rolesByUser.set(r.user_id, list);
  }

  const items: UserShape[] = rows.map((p) => {
    const auth = signInMap.get(p.id);
    return {
      id: p.id,
      email: auth?.email ?? p.email ?? null,
      name: p.full_name,
      role: pickPrimaryRole(rolesByUser, p.id),
      active: p.active,
      createdAt: p.created_at,
      lastSignInAt: auth?.last ?? null,
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

  const { data: profile, error: pErr } = await supabaseAdmin
    .from("profiles")
    .select("id,email,full_name,created_at,organization_id,active")
    .eq("id", id)
    .is("deleted_at", null)
    .maybeSingle();
  if (pErr) return jsonFail(c, 503, pErr.message, "UNAVAILABLE");
  if (!profile) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const [{ data: roleRows, error: rErr }, authRes] = await Promise.all([
    supabaseAdmin.from("user_roles").select("role,created_at").eq("user_id", id),
    supabaseAdmin.auth.admin.getUserById(id),
  ]);
  if (rErr) return jsonFail(c, 503, rErr.message, "UNAVAILABLE");
  if (authRes.error) return jsonFail(c, 503, authRes.error.message, "UNAVAILABLE");

  const rolesByUser = new Map<string, Array<{ role: string; created_at?: string }>>();
  rolesByUser.set(
    id,
    (roleRows ?? []).map((r) => ({ role: (r as { role: string }).role, created_at: (r as { created_at?: string }).created_at })),
  );

  const user: UserShape = {
    id: profile.id,
    email: authRes.data.user?.email ?? profile.email ?? null,
    name: profile.full_name,
    role: pickPrimaryRole(rolesByUser, id),
    active: (profile as { active: boolean }).active,
    createdAt: profile.created_at,
    lastSignInAt: authRes.data.user?.last_sign_in_at ?? null,
  };
  return jsonOk(c, { ok: true, data: user });
});

adminUsersRoute.patch("/:id/role", async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) return jsonFail(c, 400, "id de usuário inválido (UUID).", "VALIDATION_ERROR");

  const body = await c.req.json().catch(() => null);
  const role = (body as { role?: string } | null)?.role?.trim();
  if (!role) return jsonFail(c, 400, "Body inválido: role é obrigatória.", "VALIDATION_ERROR");
  if (!isRole(role)) {
    return jsonFail(c, 400, `role inválida. Use: ${APP_ROLES.join(", ")}.`, "VALIDATION_ERROR");
  }

  const { data: profile, error: pErr } = await supabaseAdmin
    .from("profiles")
    .select("id,organization_id")
    .eq("id", id)
    .is("deleted_at", null)
    .maybeSingle();
  if (pErr) return jsonFail(c, 503, pErr.message, "UNAVAILABLE");
  if (!profile) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const organizationId = (profile as { organization_id: string | null }).organization_id ?? null;
  const del = await supabaseAdmin.from("user_roles").delete().eq("user_id", id).eq("organization_id", organizationId);
  if (del.error) return jsonFail(c, 503, del.error.message, "UNAVAILABLE");

  const ins = await supabaseAdmin
    .from("user_roles")
    .insert({ user_id: id, organization_id: organizationId, role });
  if (ins.error) return jsonFail(c, 503, ins.error.message, "UNAVAILABLE");

  return jsonOk(c, { ok: true, data: { id, role } });
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
    .from("profiles")
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
    .from("profiles")
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
    .from("profiles")
    .select("id,organization_id")
    .eq("id", id)
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

