import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const feedbackRoute = new Hono();

/** Lista mensagens para o dashboard Korven (API key = METRICS / ADMIN). */
feedbackRoute.get("/messages", async (c) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;

  const rawLimit = c.req.query("limit");
  const limit = Math.min(500, Math.max(1, parseInt(rawLimit ?? "200", 10) || 200));

  try {
    const { data, error } = await supabaseAdmin
      .from("feedback_messages")
      .select("id,created_at,user_id,organization_id,user_email,user_full_name,body")
      .order("created_at", { ascending: false })
      .limit(limit);

    if (error) {
      return jsonFail(c, 502, error.message, "UNAVAILABLE");
    }

    return jsonOk(c, {
      ok: true as const,
      data: data ?? [],
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return jsonFail(c, 503, message, "INTERNAL_ERROR");
  }
});

feedbackRoute.delete("/messages/:id", async (c) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;

  const id = c.req.param("id");
  if (!UUID_RE.test(id)) {
    return jsonFail(c, 400, "id da mensagem inválido (UUID).", "VALIDATION_ERROR");
  }

  const { error, count } = await supabaseAdmin.from("feedback_messages").delete({ count: "exact" }).eq("id", id);
  if (error) {
    return jsonFail(c, 502, error.message, "UNAVAILABLE");
  }
  if ((count ?? 0) < 1) {
    return jsonFail(c, 404, "Mensagem não encontrada.", "NOT_FOUND");
  }

  return jsonOk(c, { ok: true as const, data: { id, deleted: true as const } });
});
