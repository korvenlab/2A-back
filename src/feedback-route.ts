import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

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
