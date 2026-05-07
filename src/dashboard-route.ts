import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const dashboardRoute = new Hono();

function parsePositiveInt(raw: string | undefined, fallback: number, min: number, max: number) {
  if (!raw) return { ok: true as const, value: fallback };
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || Number.isNaN(parsed)) {
    return { ok: false as const, message: "deve ser inteiro" };
  }
  if (parsed < min || parsed > max) {
    return { ok: false as const, message: `deve estar entre ${min} e ${max}` };
  }
  return { ok: true as const, value: parsed };
}

dashboardRoute.get("/", async (c) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;

  const orgRaw = c.req.query("organization_id")?.trim();
  let organizationId: string | null = null;
  if (orgRaw) {
    if (!UUID_RE.test(orgRaw)) {
      return c.json(
        { ok: false, error: "organization_id deve ser um UUID válido.", code: "VALIDATION_ERROR" },
        400,
      );
    }
    organizationId = orgRaw;
  }

  const periodDaysParsed = parsePositiveInt(c.req.query("period_days"), 30, 1, 365);
  if (!periodDaysParsed.ok) {
    return c.json(
      { ok: false, error: `period_days ${periodDaysParsed.message}.`, code: "VALIDATION_ERROR" },
      400,
    );
  }
  const chartDaysParsed = parsePositiveInt(c.req.query("chart_days"), 14, 1, 90);
  if (!chartDaysParsed.ok) {
    return c.json(
      { ok: false, error: `chart_days ${chartDaysParsed.message}.`, code: "VALIDATION_ERROR" },
      400,
    );
  }
  const periodDays = periodDaysParsed.value;
  const chartDays = chartDaysParsed.value;

  try {
    const { data, error } = await supabaseAdmin.rpc("dashboard_full_payload", {
      p_organization_id: organizationId,
      p_period_days: periodDays,
      p_chart_days: chartDays,
    });

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

    const payload = data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
    const kpis = ((payload.kpis as Record<string, unknown>) ?? {}) as Record<string, Record<string, unknown>>;
    const doisAvendas = ((payload.dois_avendas as Record<string, unknown>) ?? {}) as Record<string, unknown>;
    const eventosRecentes = (Array.isArray(payload.eventos_recentes) ? payload.eventos_recentes : []) as Array<
      Record<string, unknown>
    >;
    const ui = ((payload.ui as Record<string, unknown>) ?? {}) as Record<string, unknown>;
    const sidebarItens = Array.isArray(ui.sidebar_itens) ? ui.sidebar_itens : [];

    const asNumber = (v: unknown, fallback = 0) => {
      const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : fallback;
      return Number.isFinite(n) ? n : fallback;
    };

    const volumePorDiaRaw = Array.isArray(doisAvendas.volume_por_dia) ? doisAvendas.volume_por_dia : [];
    const volumePorDia = volumePorDiaRaw.map((item) => {
      const obj = (item ?? {}) as Record<string, unknown>;
      return {
        data: String(obj.dia ?? obj.data ?? ""),
        volume: asNumber(obj.transacoes ?? obj.volume ?? 0),
      };
    });

    const eventos = eventosRecentes.map((ev, idx) => ({
      id: String(ev.id ?? `${ev.app ?? "core"}-${idx}`),
      app: (ev.app === "2avendas" || ev.app === "core" ? ev.app : "core") as "2avendas" | "core",
      status: (ev.status === "online" || ev.status === "degraded" || ev.status === "offline" ? ev.status : "online") as
        | "online"
        | "degraded"
        | "offline",
      message: String(ev.mensagem ?? ev.message ?? ""),
      timestamp: String(ev.timestamp ?? ev.created_at ?? ""),
    }));

    const kpiReceita = (kpis.receita_total ?? {}) as Record<string, unknown>;
    const kpiVolume = (kpis.volume_vendas_2avendas ?? {}) as Record<string, unknown>;
    const kpiUptime = (kpis.uptime_medio ?? {}) as Record<string, unknown>;

    return c.json({
      ok: true,
      gerado_em: String(payload.gerado_em ?? new Date().toISOString()),
      filtros: payload.filtros ?? {
        organization_id: organizationId,
        period_days: periodDays,
        chart_days: chartDays,
      },
      kpis: {
        receita_total: {
          valor: asNumber(kpiReceita.valor_reais ?? kpiReceita.valor),
          delta_pct: asNumber(kpiReceita.variacao_pct ?? kpiReceita.delta_pct),
        },
        volume_vendas_2avendas: {
          valor: asNumber(kpiVolume.valor),
          delta_pct: asNumber(kpiVolume.variacao_pct ?? kpiVolume.delta_pct),
        },
        uptime_medio: {
          valor: asNumber(kpiUptime.valor_pct ?? kpiUptime.valor),
          delta_pct: asNumber(kpiUptime.variacao_pct ?? kpiUptime.delta_pct, 0),
        },
      },
      dois_avendas: {
        volume_por_dia: volumePorDia,
      },
      eventos_recentes: eventos,
      ui: {
        sidebar_itens: sidebarItens.map((item) => {
          const obj = (item ?? {}) as Record<string, unknown>;
          return {
            label: String(obj.label ?? ""),
            href:
              obj.id === "overview"
                ? "/"
                : obj.id === "wagoo"
                  ? "/wagoo"
                  : obj.id === "2avendas"
                    ? "/2avendas"
                    : "/settings",
            icon: String(obj.id ?? "circle"),
          };
        }),
        topbar: {
          title: "Dashboard Agregador",
          subtitle: "Wagoo + 2AVENDAS + Core",
        },
      },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: message, code: "INTERNAL_ERROR" }, 503);
  }
});
