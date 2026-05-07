import type { Context } from "hono";
import { jsonFail } from "./json-response.js";

export function extractApiKey(
  headerAuth: string | undefined,
  headerKey: string | undefined,
  headerAdminSecret: string | undefined,
): string | undefined {
  const bearer = headerAuth?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  if (bearer) return bearer;
  const xk = headerKey?.trim();
  if (xk) return xk;
  return headerAdminSecret?.trim();
}

/** Retorna Response JSON se o pedido deve ser bloqueado; caso contrário null (autorizado). */
export function metricsApiKeyUnauthorizedResponse(c: Context): Response | null {
  const expected = process.env.ADMIN_API_KEY?.trim() || process.env.METRICS_API_KEY?.trim();
  if (!expected) {
    return jsonFail(c, 503, "Serviço indisponível: ADMIN_API_KEY/METRICS_API_KEY não configurada.", "UNAVAILABLE");
  }
  const provided = extractApiKey(
    c.req.header("Authorization"),
    c.req.header("X-API-Key"),
    c.req.header("x-admin-secret"),
  );
  if (!provided || provided !== expected) {
    return jsonFail(c, 401, "API Key inválida ou ausente.", "UNAUTHORIZED");
  }
  return null;
}
