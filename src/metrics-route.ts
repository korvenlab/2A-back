import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

export const metricsRoute = new Hono();

metricsRoute.get("/", async (c) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;

  try {
    const { data, error } = await supabaseAdmin.rpc("dashboard_metrics_summary");

    if (error) {
      return c.json(
        {
          ok: false,
          error: error.message,
          code: "INTERNAL_ERROR",
        },
        502,
      );
    }

    const raw = data as {
      assinaturas?: {
        quantidade?: number | string;
        quantidade_pagas?: number | string;
        quantidade_nao_pagas?: number | string;
        soma_valor_mensal?: number | string;
        soma_valor_mensal_pago?: number | string;
        soma_valor_mensal_pendente?: number | string;
      };
      vendas?: { quantidade?: number | string; soma_valor_total?: number | string };
      gerado_em?: string;
    };

    const num = (v: number | string | undefined) =>
      typeof v === "string" ? Number(v) : Number(v ?? 0);

    const int = (v: number | string | undefined) => Math.trunc(num(v));

    return c.json({
      ok: true,
      gerado_em: raw?.gerado_em ?? null,
      assinaturas: {
        quantidade: int(raw?.assinaturas?.quantidade),
        quantidade_pagas: int(raw?.assinaturas?.quantidade_pagas),
        quantidade_nao_pagas: int(raw?.assinaturas?.quantidade_nao_pagas),
        soma_valor_mensal: num(raw?.assinaturas?.soma_valor_mensal),
        soma_valor_mensal_pago: num(raw?.assinaturas?.soma_valor_mensal_pago),
        soma_valor_mensal_pendente: num(raw?.assinaturas?.soma_valor_mensal_pendente),
      },
      vendas: {
        quantidade: int(raw?.vendas?.quantidade),
        soma_valor_total: num(raw?.vendas?.soma_valor_total),
      },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: message, code: "INTERNAL_ERROR" }, 503);
  }
});
