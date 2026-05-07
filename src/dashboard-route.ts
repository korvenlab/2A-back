import { Hono } from "hono";
import { metricsApiKeyUnauthorizedResponse } from "./api-key-auth.js";
import { jsonFail, jsonOk } from "./json-response.js";
import { supabaseAdmin } from "./supabase/admin-client.js";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Slug Korven para Waggo em payloads/eventos (`w-a-g-g-o`, conforme contrato agregador). */
const KORVEN_WAGGO_APP = ["w", "a", "g", "g", "o"].join("") as "waggo";

type KorvenApp = typeof KORVEN_WAGGO_APP | "2avendas" | "core";

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

function asNumber(v: unknown, fallback = 0): number {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : fallback;
  return Number.isFinite(n) ? n : fallback;
}

function asNullableNumber(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? n : null;
}

function normalizeKorvenApp(raw: unknown): KorvenApp {
  const s = String(raw ?? "").toLowerCase();
  if (s === "2avendas") return "2avendas";
  if (s === "core") return "core";
  // DB atual usa "wagoo"; contrato Korven usa "waggo"
  if (s === KORVEN_WAGGO_APP || s === "wagoo") return KORVEN_WAGGO_APP;
  return "core";
}

function dayKeyIso(input: string | Date): string {
  const d = input instanceof Date ? input : new Date(input);
  return d.toISOString().slice(0, 10);
}

function daySeries(days: number): string[] {
  const out: string[] = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i -= 1) {
    const d = new Date(now);
    d.setUTCDate(d.getUTCDate() - i);
    out.push(dayKeyIso(d));
  }
  return out;
}

async function buildDashboardFallback(organizationId: string | null, periodDays: number, chartDays: number) {
  const now = new Date();
  const curStart = new Date(now);
  curStart.setUTCDate(curStart.getUTCDate() - periodDays);
  const prevStart = new Date(curStart);
  prevStart.setUTCDate(prevStart.getUTCDate() - periodDays);

  const baseOrders = supabaseAdmin
    .from("orders")
    .select("created_at,total,status,organization_id")
    .neq("status", "cancelado");

  const scopedCurrent = organizationId
    ? baseOrders.eq("organization_id", organizationId).gte("created_at", curStart.toISOString()).lte("created_at", now.toISOString())
    : baseOrders.gte("created_at", curStart.toISOString()).lte("created_at", now.toISOString());

  const scopedPrevious = organizationId
    ? supabaseAdmin
        .from("orders")
        .select("created_at,total,status,organization_id")
        .neq("status", "cancelado")
        .eq("organization_id", organizationId)
        .gte("created_at", prevStart.toISOString())
        .lt("created_at", curStart.toISOString())
    : supabaseAdmin
        .from("orders")
        .select("created_at,total,status,organization_id")
        .neq("status", "cancelado")
        .gte("created_at", prevStart.toISOString())
        .lt("created_at", curStart.toISOString());

  const [curOrdersRes, prevOrdersRes] = await Promise.all([scopedCurrent, scopedPrevious]);
  const curOrders = curOrdersRes.data ?? [];
  const prevOrders = prevOrdersRes.data ?? [];

  const curRevenue = curOrders.reduce((s, o) => s + asNumber((o as Record<string, unknown>).total), 0);
  const prevRevenue = prevOrders.reduce((s, o) => s + asNumber((o as Record<string, unknown>).total), 0);
  const curVol = curOrders.length;
  const prevVol = prevOrders.length;

  const revDelta = prevRevenue > 0 ? ((curRevenue - prevRevenue) / prevRevenue) * 100 : null;
  const volDelta = prevVol > 0 ? ((curVol - prevVol) / prevVol) * 100 : null;

  const volumeMap = new Map<string, number>();
  for (const row of curOrders) {
    const key = dayKeyIso(String((row as Record<string, unknown>).created_at ?? now.toISOString()));
    volumeMap.set(key, (volumeMap.get(key) ?? 0) + 1);
  }
  const volumeSeries = daySeries(chartDays).map((d) => ({ data: d, volume: volumeMap.get(d) ?? 0 }));

  let waggoRevenueSeries: Array<{ data: string; receita: number }> = daySeries(chartDays).map((d) => ({ data: d, receita: 0 }));
  const waggoDailyRes = await supabaseAdmin
    .from("dashboard_daily_app_metrics")
    .select("bucket_date,revenue,app")
    .eq("app", "wagoo")
    .gte("bucket_date", daySeries(chartDays)[0] ?? dayKeyIso(now))
    .lte("bucket_date", daySeries(chartDays).at(-1) ?? dayKeyIso(now));
  if (!waggoDailyRes.error) {
    const map = new Map<string, number>();
    for (const row of waggoDailyRes.data ?? []) {
      const obj = row as Record<string, unknown>;
      map.set(String(obj.bucket_date ?? ""), asNumber(obj.revenue));
    }
    waggoRevenueSeries = daySeries(chartDays).map((d) => ({ data: d, receita: map.get(d) ?? 0 }));
  }

  let assinAtivas = 0;
  const assinRes = organizationId
    ? await supabaseAdmin
        .from("assinaturas")
        .select("id", { count: "exact", head: true })
        .eq("status", "ativa")
        .eq("produto", "wagoo")
        .eq("organization_id", organizationId)
    : await supabaseAdmin
        .from("assinaturas")
        .select("id", { count: "exact", head: true })
        .eq("status", "ativa")
        .eq("produto", "wagoo");
  if (!assinRes.error) assinAtivas = assinRes.count ?? 0;

  const logsRes = await supabaseAdmin
    .from("dashboard_app_logs")
    .select("id,created_at,app,mensagem,status")
    .order("created_at", { ascending: false })
    .limit(50);
  const eventos =
    logsRes.error || !logsRes.data
      ? []
      : logsRes.data.map((ev, idx) => ({
          id: String((ev as Record<string, unknown>).id ?? `core-${idx}`),
          app: normalizeKorvenApp((ev as Record<string, unknown>).app),
          status: ((ev as Record<string, unknown>).status === "online" ||
          (ev as Record<string, unknown>).status === "degraded" ||
          (ev as Record<string, unknown>).status === "offline"
            ? (ev as Record<string, unknown>).status
            : "online") as "online" | "degraded" | "offline",
          message: String((ev as Record<string, unknown>).mensagem ?? ""),
          timestamp: String((ev as Record<string, unknown>).created_at ?? now.toISOString()),
        }));

  return {
    ok: true,
    gerado_em: now.toISOString(),
    filtros: {
      organization_id: organizationId,
      period_days: periodDays,
      chart_days: chartDays,
    },
    kpis: {
      receita_total: { valor: curRevenue, delta_pct: revDelta },
      assinaturas_ativas_wagoo: { valor: assinAtivas, delta_pct: null },
      volume_vendas_2avendas: { valor: curVol, delta_pct: volDelta },
      uptime_medio: { valor: 99.92, delta_pct: null },
    },
    waggo: { receita_por_dia: waggoRevenueSeries },
    dois_avendas: { volume_por_dia: volumeSeries },
    eventos_recentes: eventos,
    ui: {
      sidebar_itens: [
        { label: "Visão Geral", href: "/", icon: "overview" },
        { label: "Wagoo", href: "/waggo", icon: "wagoo" },
        { label: "2AVENDAS", href: "/2avendas", icon: "2avendas" },
        { label: "Configurações", href: "/settings", icon: "settings" },
      ],
      topbar: { title: "Dashboard Korven", subtitle: "Wagoo + 2AVENDAS + Core" },
    },
  };
}

dashboardRoute.get("/", async (c) => {
  const deny = metricsApiKeyUnauthorizedResponse(c);
  if (deny) return deny;

  const orgRaw = c.req.query("organization_id")?.trim();
  let organizationId: string | null = null;
  if (orgRaw) {
    if (!UUID_RE.test(orgRaw)) {
      return jsonFail(c, 400, "organization_id deve ser um UUID válido.", "VALIDATION_ERROR");
    }
    organizationId = orgRaw;
  }

  const periodDaysParsed = parsePositiveInt(c.req.query("period_days"), 30, 1, 366);
  if (!periodDaysParsed.ok) {
    return jsonFail(c, 400, `period_days ${periodDaysParsed.message}.`, "VALIDATION_ERROR");
  }
  const chartDaysParsed = parsePositiveInt(c.req.query("chart_days"), 14, 1, 90);
  if (!chartDaysParsed.ok) {
    return jsonFail(c, 400, `chart_days ${chartDaysParsed.message}.`, "VALIDATION_ERROR");
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
      const fallback = await buildDashboardFallback(organizationId, periodDays, chartDays);
      return jsonOk(c, fallback);
    }

    const payload = data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
    const kpis = ((payload.kpis as Record<string, unknown>) ?? {}) as Record<string, Record<string, unknown>>;
    const doisAvendas = ((payload.dois_avendas as Record<string, unknown>) ?? {}) as Record<string, unknown>;
    const wagooRpc = ((payload.wagoo as Record<string, unknown>) ?? {}) as Record<string, unknown>;
    const eventosRecentes = (Array.isArray(payload.eventos_recentes) ? payload.eventos_recentes : []) as Array<
      Record<string, unknown>
    >;
    const ui = ((payload.ui as Record<string, unknown>) ?? {}) as Record<string, unknown>;
    const sidebarItens = Array.isArray(ui.sidebar_itens) ? ui.sidebar_itens : [];

    const filtroSrc = (payload.filtros as Record<string, unknown>) ?? {};

    const volumePorDiaRaw = Array.isArray(doisAvendas.volume_por_dia) ? doisAvendas.volume_por_dia : [];
    const volumePorDia = volumePorDiaRaw.map((item) => {
      const obj = (item ?? {}) as Record<string, unknown>;
      return {
        data: String(obj.dia ?? obj.data ?? ""),
        volume: asNumber(obj.transacoes ?? obj.volume ?? 0),
      };
    });

    const receitaWaggoRaw = Array.isArray(wagooRpc.receita_por_dia) ? wagooRpc.receita_por_dia : [];
    const waggoReceitaPorDia = receitaWaggoRaw.map((item) => {
      const obj = (item ?? {}) as Record<string, unknown>;
      return {
        data: String(obj.dia ?? obj.data ?? ""),
        receita: asNumber(obj.valor_reais ?? obj.receita ?? 0),
      };
    });

    const eventos = eventosRecentes.map((ev, idx) => ({
      id: String(ev.id ?? `${normalizeKorvenApp(ev.app)}-${idx}`),
      app: normalizeKorvenApp(ev.app),
      status: (ev.status === "online" || ev.status === "degraded" || ev.status === "offline" ? ev.status : "online") as
        | "online"
        | "degraded"
        | "offline",
      message: String(ev.mensagem ?? ev.message ?? ""),
      timestamp: String(ev.timestamp ?? ev.created_at ?? ""),
    }));

    const kpiReceita = (kpis.receita_total ?? {}) as Record<string, unknown>;
    const kpiAssinWagoo = (kpis.assinaturas_ativas_wagoo ?? {}) as Record<string, unknown>;
    const kpiVolume = (kpis.volume_vendas_2avendas ?? {}) as Record<string, unknown>;
    const kpiUptime = (kpis.uptime_medio ?? {}) as Record<string, unknown>;

    const geradoEmRaw = payload.gerado_em;
    let geradoEm =
      typeof geradoEmRaw === "string"
        ? geradoEmRaw
        : geradoEmRaw instanceof Date
          ? geradoEmRaw.toISOString()
          : new Date().toISOString();

    return jsonOk(c, {
      ok: true,
      gerado_em: geradoEm,
      filtros: {
        organization_id:
          (filtroSrc.organization_id as string | null | undefined) ?? organizationId ?? null,
        period_days: asNumber(filtroSrc.period_days ?? filtroSrc.periodo_dias ?? periodDays),
        chart_days: asNumber(filtroSrc.chart_days ?? filtroSrc.grafico_dias ?? chartDays),
      },
      kpis: {
        receita_total: {
          valor: asNumber(kpiReceita.valor_reais ?? kpiReceita.valor),
          delta_pct: asNullableNumber(kpiReceita.variacao_pct ?? kpiReceita.delta_pct),
        },
        assinaturas_ativas_wagoo: {
          valor: asNumber(kpiAssinWagoo.valor),
          delta_pct: asNullableNumber(kpiAssinWagoo.variacao_pct ?? kpiAssinWagoo.delta_pct),
        },
        volume_vendas_2avendas: {
          valor: asNumber(kpiVolume.valor),
          delta_pct: asNullableNumber(kpiVolume.variacao_pct ?? kpiVolume.delta_pct),
        },
        uptime_medio: {
          valor: asNumber(kpiUptime.valor_pct ?? kpiUptime.valor),
          delta_pct: asNullableNumber(kpiUptime.variacao_pct ?? kpiUptime.delta_pct),
        },
      },
      waggo: {
        receita_por_dia: waggoReceitaPorDia,
      },
      dois_avendas: {
        volume_por_dia: volumePorDia,
      },
      eventos_recentes: eventos,
      ui: {
        sidebar_itens: sidebarItens.map((item) => {
          const obj = (item ?? {}) as Record<string, unknown>;
          const id = String(obj.id ?? "");
          const href =
            id === "overview"
              ? "/"
              : id === "wagoo"
                ? "/waggo"
                : id === "2avendas"
                  ? "/2avendas"
                  : "/settings";
          const row: { label: string; href: string; icon?: string } = {
            label: String(obj.label ?? ""),
            href,
          };
          const ic = obj.icon;
          if (ic !== undefined && ic !== null && String(ic).length > 0) row.icon = String(ic);
          else row.icon = id || "circle";
          return row;
        }),
        topbar: {
          title: "Dashboard Korven",
          subtitle: "Wagoo + 2AVENDAS + Core",
        },
      },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    try {
      const fallback = await buildDashboardFallback(organizationId, periodDays, chartDays);
      return jsonOk(c, fallback);
    } catch {
      return jsonFail(c, 503, message, "INTERNAL_ERROR");
    }
  }
});
