import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

interface RoleRow {
  slug: string;
  label: string;
  description: string | null;
}

interface PermissionRow {
  role_slug: string;
  permission: string;
}

export const adminRolesRoute = new Hono();

adminRolesRoute.use("*", async (c, next) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;
  return next();
});

adminRolesRoute.get("/", async (c) => {
  const [{ data: roles, error: rolesErr }, { data: permissions, error: permsErr }] = await Promise.all([
    (supabaseAdmin as any)
      .from("app_roles_catalog")
      .select("slug,label,description")
      .order("slug", { ascending: true }),
    (supabaseAdmin as any)
      .from("app_role_permissions")
      .select("role_slug,permission")
      .order("role_slug", { ascending: true }),
  ]);

  if (rolesErr) return jsonFail(c, 503, rolesErr.message, "UNAVAILABLE");
  if (permsErr) return jsonFail(c, 503, permsErr.message, "UNAVAILABLE");

  const roleRows = ((roles ?? []) as unknown[]) as RoleRow[];
  const permRows = ((permissions ?? []) as unknown[]) as PermissionRow[];

  const permissionsByRole = new Map<string, string[]>();
  for (const p of permRows) {
    const list = permissionsByRole.get(p.role_slug) ?? [];
    list.push(p.permission);
    permissionsByRole.set(p.role_slug, list);
  }

  const items = roleRows.map((r) => ({
    slug: r.slug,
    label: r.label,
    description: r.description,
    permissions: permissionsByRole.get(r.slug) ?? [],
  }));

  return jsonOk(c, { ok: true, data: { items, total: items.length } });
});
