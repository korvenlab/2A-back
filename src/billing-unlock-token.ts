import crypto from "node:crypto";

const VERSION = 1;
const DEFAULT_TTL_SEC = 7 * 24 * 3600;
const MAX_TTL_SEC = 30 * 24 * 3600;

function signingSecret(): string | null {
  return process.env.KORVEN_BILLING_ADMIN_SECRET?.trim() || null;
}

export type MintBillingUnlockResult = {
  token: string;
  /** ISO 8601 */
  expires_at: string;
};

/** Gera token opaco (HMAC) para link de liberação manual (Korven Dashboard → cliente). */
export function mintBillingUnlockToken(
  organizationId: string,
  ttlSec: number = DEFAULT_TTL_SEC,
): MintBillingUnlockResult | null {
  const secret = signingSecret();
  if (!secret) return null;
  const ttl = Math.min(Math.max(ttlSec, 120), MAX_TTL_SEC);
  const exp = Math.floor(Date.now() / 1000) + ttl;
  const payload = JSON.stringify({ v: VERSION, oid: organizationId, exp });
  const payloadB64 = Buffer.from(payload, "utf8").toString("base64url");
  const sig = crypto.createHmac("sha256", secret).update(payloadB64).digest("base64url");
  return {
    token: `${payloadB64}.${sig}`,
    expires_at: new Date(exp * 1000).toISOString(),
  };
}

export function verifyBillingUnlockToken(token: string): { organizationId: string } | null {
  const secret = signingSecret();
  if (!secret) return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payloadB64, sig] = parts;
  if (!payloadB64 || !sig) return null;
  const expected = crypto.createHmac("sha256", secret).update(payloadB64).digest("base64url");
  const a = Buffer.from(sig, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  let data: { v?: number; oid?: string; exp?: number };
  try {
    data = JSON.parse(Buffer.from(payloadB64, "base64url").toString("utf8")) as {
      v?: number;
      oid?: string;
      exp?: number;
    };
  } catch {
    return null;
  }
  if (data.v !== VERSION || typeof data.oid !== "string" || typeof data.exp !== "number") return null;
  if (data.exp < Math.floor(Date.now() / 1000)) return null;
  return { organizationId: data.oid };
}
