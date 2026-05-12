import type { KorvenErrorCode } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const ROLE_PRIORITY = ["admin", "vendedor", "cliente"] as const;

function roleRank(slug: string | null | undefined): number {
  const s = slug?.trim().toLowerCase() ?? "";
  const i = ROLE_PRIORITY.indexOf(s as (typeof ROLE_PRIORITY)[number]);
  return i === -1 ? 999 : i;
}

export function strongestRoleSlug(...candidates: (string | null | undefined)[]): string | null {
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

export type BearerSessionResolved = {
  userId: string;
  email: string | null;
  organizationId: string | null;
  roleSlug: string | null;
  /** app_users.active === false */
  inactive: boolean;
  inactiveAppRole: string | null;
  inactiveOrganizationId: string | null;
};

export type BearerSessionResult =
  | { ok: true; data: BearerSessionResolved }
  | { ok: false; status: number; message: string; code: KorvenErrorCode };

export async function resolveBearerSession(token: string): Promise<BearerSessionResult> {
  const { data: authData, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !authData.user) {
    return { ok: false, status: 401, message: "Sessão inválida ou expirada.", code: "UNAUTHORIZED" };
  }

  const userId = authData.user.id;
  const email = authData.user.email ?? null;

  const { data: auRow, error: auErr } = await supabaseAdmin
    .from("app_users")
    .select("role, organization_id, active")
    .eq("id", userId)
    .is("deleted_at", null)
    .maybeSingle();

  if (auErr) return { ok: false, status: 503, message: auErr.message, code: "UNAVAILABLE" };

  const au = auRow as {
    role: string | null;
    organization_id: string | null;
    active: boolean | null;
  } | null;

  if (au && au.active === false) {
    return {
      ok: true,
      data: {
        userId,
        email,
        organizationId: au.organization_id ?? null,
        roleSlug: strongestRoleSlug(au.role),
        inactive: true,
        inactiveAppRole: au.role,
        inactiveOrganizationId: au.organization_id ?? null,
      },
    };
  }

  let organizationId: string | null = au && au.active !== false ? au.organization_id ?? null : null;

  const { data: urRows, error: urErr } = await supabaseAdmin
    .from("user_roles")
    .select("role, organization_id")
    .eq("user_id", userId);

  if (urErr) return { ok: false, status: 503, message: urErr.message, code: "UNAVAILABLE" };

  type Ur = { role: string | null; organization_id: string | null };
  const urList = (urRows ?? []) as Ur[];

  const roleSlug = strongestRoleSlug(au?.role, ...urList.map((r) => r.role));

  if (!organizationId && roleSlug) {
    const matchOrg = urList.find(
      (r) => String(r.role ?? "").trim().toLowerCase() === roleSlug,
    );
    organizationId = matchOrg?.organization_id ?? urList[0]?.organization_id ?? null;
  }

  return {
    ok: true,
    data: {
      userId,
      email,
      organizationId,
      roleSlug,
      inactive: false,
      inactiveAppRole: null,
      inactiveOrganizationId: null,
    },
  };
}
