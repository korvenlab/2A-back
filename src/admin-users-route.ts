import { createHash } from "node:crypto";
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

const COMMAND_TYPES = new Set([
  "role.set",
  "status.set",
  "plan.set",
  "access.grant",
  "user.delete",
]);

type ControlPlaneCommand = {
  command?: string;
  type?: string;
  external_user_id?: string;
  user_id?: string;
  organization_id?: string;
  payload?: Record<string, unknown>;
};

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJson(child)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
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

/** Full paginated snapshot consumed by the control plane for reconciliation. */
adminUsersRoute.get("/sync", async (c) => {
  const pg = parsePagination(c.req.query("page"), c.req.query("limit"));
  if (!pg.ok) return jsonFail(c, 400, pg.message, "VALIDATION_ERROR");
  const { page, limit } = pg;
  const from = (page - 1) * limit;
  const to = from + limit - 1;
  const updatedAfter = c.req.query("updated_after")?.trim();

  let query = supabaseAdmin
    .from("app_users")
    .select(
      "id,email,name,role,active,last_sign_in_at,created_at,updated_at,deleted_at,organization_id,billing_stripe_access_at,billing_complimentary_access_until",
      { count: "exact" },
    )
    .order("updated_at", { ascending: true })
    .order("id", { ascending: true });
  if (updatedAfter) {
    const parsed = Date.parse(updatedAfter);
    if (!Number.isFinite(parsed)) {
      return jsonFail(c, 400, "updated_after deve ser uma data ISO válida.", "VALIDATION_ERROR");
    }
    query = query.gt("updated_at", new Date(parsed).toISOString());
  }

  const { data, error, count } = await query.range(from, to);
  if (error) return jsonFail(c, 503, error.message, "UNAVAILABLE");
  const rows = data ?? [];
  const orgIds = [...new Set(rows.map((row) => row.organization_id).filter((id): id is string => !!id))];
  const plansByOrg = new Map<string, { plan: string | null; status: string; paid: boolean }>();
  if (orgIds.length > 0) {
    const { data: subscriptions, error: subscriptionsError } = await supabaseAdmin
      .from("assinaturas")
      .select("organization_id,plano,status,pago,updated_at")
      .in("organization_id", orgIds)
      .order("updated_at", { ascending: false });
    if (subscriptionsError) return jsonFail(c, 503, subscriptionsError.message, "UNAVAILABLE");
    for (const subscription of subscriptions ?? []) {
      if (subscription.organization_id && !plansByOrg.has(subscription.organization_id)) {
        plansByOrg.set(subscription.organization_id, {
          plan: subscription.plano,
          status: subscription.status,
          paid: subscription.pago,
        });
      }
    }
  }

  const items = rows.map((row) => ({
    external_user_id: row.id,
    organization_id: row.organization_id,
    email: row.email,
    name: row.name,
    role: row.role,
    status: row.deleted_at ? "deleted" : row.active ? "active" : "inactive",
    plan: row.organization_id ? plansByOrg.get(row.organization_id) ?? null : null,
    access: {
      stripe_paid: !!row.billing_stripe_access_at,
      complimentary_until: row.billing_complimentary_access_until,
    },
    created_at: row.created_at,
    updated_at: row.updated_at,
    last_sign_in_at: row.last_sign_in_at,
  }));
  return jsonOk(c, {
    ok: true,
    data: {
      items,
      page,
      limit,
      total: count ?? 0,
      has_more: from + items.length < (count ?? 0),
    },
  });
});

/** Idempotent command endpoint used by the Korven control plane. */
adminUsersRoute.post("/commands", async (c) => {
  const idempotencyKey = c.req.header("Idempotency-Key")?.trim();
  if (!idempotencyKey || idempotencyKey.length > 200) {
    return jsonFail(c, 400, "Idempotency-Key é obrigatório (máximo 200 caracteres).", "VALIDATION_ERROR");
  }

  const body = (await c.req.json().catch(() => null)) as ControlPlaneCommand | null;
  const commandType = body?.command?.trim() || body?.type?.trim() || "";
  const userId = body?.external_user_id?.trim() || body?.user_id?.trim() || "";
  const organizationId = body?.organization_id?.trim() || "";
  const payload = body?.payload ?? {};
  const requestHash = createHash("sha256").update(canonicalJson(body)).digest("hex");
  if (!COMMAND_TYPES.has(commandType)) {
    return jsonFail(c, 400, "Comando inválido.", "VALIDATION_ERROR");
  }
  if (!userId || !UUID_RE.test(userId)) {
    return jsonFail(c, 400, "external_user_id deve ser um UUID válido.", "VALIDATION_ERROR");
  }
  if (organizationId && !UUID_RE.test(organizationId)) {
    return jsonFail(c, 400, "organization_id deve ser um UUID válido.", "VALIDATION_ERROR");
  }

  const receipts = (supabaseAdmin as any).from("control_plane_command_receipts");
  const claimed = await receipts.insert({
    idempotency_key: idempotencyKey,
    command_type: commandType,
    request_hash: requestHash,
    status: "processing",
  });
  if (claimed.error?.code === "23505") {
    const previous = await (supabaseAdmin as any)
      .from("control_plane_command_receipts")
      .select("command_type,request_hash,status,response")
      .eq("idempotency_key", idempotencyKey)
      .maybeSingle();
    if (previous.error) return jsonFail(c, 503, previous.error.message, "UNAVAILABLE");
    if (previous.data?.command_type !== commandType || previous.data?.request_hash !== requestHash) {
      return jsonFail(c, 409, "Idempotency-Key já usada com outro conteúdo.", "CONFLICT");
    }
    if (previous.data?.status === "completed") return jsonOk(c, previous.data.response);
    return jsonFail(c, 409, "Comando com esta chave ainda está em processamento.", "CONFLICT");
  }
  if (claimed.error) return jsonFail(c, 503, claimed.error.message, "UNAVAILABLE");

  let result: Record<string, unknown>;
  try {
    if (commandType === "role.set") {
      const role = typeof payload.role === "string" ? payload.role.trim().toLowerCase() : "";
      if (!isRoleValueValid(role)) throw new Error("VALIDATION:role inválida.");
      const updated = await supabaseAdmin
        .from("app_users")
        .update({ role, updated_at: new Date().toISOString() })
        .eq("id", userId)
        .is("deleted_at", null)
        .select("id")
        .maybeSingle();
      if (updated.error) throw updated.error;
      if (!updated.data) throw new Error("NOT_FOUND:Usuário não encontrado.");
      result = { external_user_id: userId, role };
    } else if (commandType === "status.set") {
      const rawStatus = payload.status;
      const active =
        typeof payload.active === "boolean"
          ? payload.active
          : rawStatus === "active"
            ? true
            : rawStatus === "inactive"
              ? false
              : null;
      if (active === null) throw new Error("VALIDATION:Informe payload.active ou status active/inactive.");
      const updated = await supabaseAdmin
        .from("app_users")
        .update(active ? { active: true, deleted_at: null } : { active: false })
        .eq("id", userId)
        .select("id")
        .maybeSingle();
      if (updated.error) throw updated.error;
      if (!updated.data) throw new Error("NOT_FOUND:Usuário não encontrado.");
      result = { external_user_id: userId, active };
    } else if (commandType === "plan.set") {
      if (!organizationId) throw new Error("VALIDATION:organization_id é obrigatório.");
      const plan = typeof payload.plan === "string" ? payload.plan.trim() : "";
      if (!plan) throw new Error("VALIDATION:payload.plan é obrigatório.");
      const status = typeof payload.status === "string" ? payload.status.trim() : "ativa";
      const value = Number(payload.monthly_value ?? 0);
      if (!Number.isFinite(value) || value < 0) throw new Error("VALIDATION:monthly_value inválido.");
      const current = await supabaseAdmin
        .from("assinaturas")
        .select("id")
        .eq("organization_id", organizationId)
        .order("updated_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (current.error) throw current.error;
      const values = { plano: plan, status, valor_mensal: value, updated_at: new Date().toISOString() };
      const changed = current.data
        ? await supabaseAdmin.from("assinaturas").update(values).eq("id", current.data.id)
        : await supabaseAdmin.from("assinaturas").insert({ organization_id: organizationId, ...values });
      if (changed.error) throw changed.error;
      result = { external_user_id: userId, organization_id: organizationId, plan, status };
    } else if (commandType === "access.grant") {
      if (!organizationId) throw new Error("VALIDATION:organization_id é obrigatório.");
      const granted = typeof payload.granted === "boolean" ? payload.granted : true;
      const changed = await supabaseAdmin
        .from("organizations")
        .update({ billing_manual_unlock: granted })
        .eq("id", organizationId)
        .select("id")
        .maybeSingle();
      if (changed.error) throw changed.error;
      if (!changed.data) throw new Error("NOT_FOUND:Organização não encontrada.");
      result = { external_user_id: userId, organization_id: organizationId, access_granted: granted };
    } else {
      const existing = await supabaseAdmin.from("app_users").select("id").eq("id", userId).maybeSingle();
      if (existing.error) throw existing.error;
      if (existing.data) {
        const deleted = await supabaseAdmin.auth.admin.deleteUser(userId);
        if (deleted.error) throw deleted.error;
      }
      result = { external_user_id: userId, deleted: true };
    }
  } catch (error) {
    await (supabaseAdmin as any)
      .from("control_plane_command_receipts")
      .delete()
      .eq("idempotency_key", idempotencyKey);
    const message = error instanceof Error ? error.message : String(error);
    if (message.startsWith("VALIDATION:")) {
      return jsonFail(c, 400, message.slice(11), "VALIDATION_ERROR");
    }
    if (message.startsWith("NOT_FOUND:")) {
      return jsonFail(c, 404, message.slice(10), "NOT_FOUND");
    }
    return jsonFail(c, 503, message, "UNAVAILABLE");
  }

  const response = { ok: true, data: { command: commandType, ...result } };
  const completed = await (supabaseAdmin as any)
    .from("control_plane_command_receipts")
    .update({ status: "completed", response, completed_at: new Date().toISOString() })
    .eq("idempotency_key", idempotencyKey);
  if (completed.error) return jsonFail(c, 503, completed.error.message, "UNAVAILABLE");
  return jsonOk(c, response);
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

  const up = await supabaseAdmin
    .from("app_users")
    .update({ role, updated_at: new Date().toISOString() })
    .eq("id", id);
  if (up.error) return jsonFail(c, 503, up.error.message, "UNAVAILABLE");

  /**
   * Espelha profile.organization_id + user_roles via trigger no banco
   * (`trg_reconcile_app_user_identity`). Korven e o app 2AVendas ficam alinhados sem duplicar lógica aqui.
   */
  const legacyRole = asLegacyRbacRole(role);
  const syncedToUserRoles = legacyRole !== null;

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

  /** Desativar só corta acesso (`active`); não marca `deleted_at`. Reativar limpa `deleted_at` legado. */
  const patch = active ? { active: true, deleted_at: null } : { active: false };
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

  const { data: row, error: findErr } = await supabaseAdmin
    .from("app_users")
    .select("id")
    .eq("id", id)
    .maybeSingle();
  if (findErr) return jsonFail(c, 503, findErr.message, "UNAVAILABLE");
  if (!row) return jsonFail(c, 404, "Usuário não encontrado.", "NOT_FOUND");

  const { error: authErr } = await supabaseAdmin.auth.admin.deleteUser(id);
  if (authErr) return jsonFail(c, 503, authErr.message, "UNAVAILABLE");

  return jsonOk(c, {
    ok: true,
    data: { id, deleted: true },
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

