import type { Context } from "hono";

export function extractApiKey(headerAuth: string | undefined, headerKey: string | undefined): string | undefined {
  const bearer = headerAuth?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  if (bearer) return bearer;
  return headerKey?.trim() || undefined;
}

/** Returns JSON Response if request must be rejected; otherwise null (authorized). */
export function metricsApiKeyUnauthorizedResponse(c: Context): Response | null {
  const expected = process.env.METRICS_API_KEY?.trim();
  if (!expected) {
    return c.json(
      { ok: false, error: "METRICS_API_KEY não está definida no servidor.", code: "INTERNAL_ERROR" },
      503,
    );
  }
  const provided = extractApiKey(c.req.header("Authorization"), c.req.header("X-API-Key"));
  if (!provided || provided !== expected) {
    return c.json({ ok: false, error: "API Key inválida ou ausente.", code: "UNAUTHORIZED" }, 401);
  }
  return null;
}
