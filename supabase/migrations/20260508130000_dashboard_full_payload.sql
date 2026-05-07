-- Produto da assinatura (Wagoo vs outros futuros)
alter table public.assinaturas
  add column if not exists produto text not null default 'wagoo';

comment on column public.assinaturas.produto is 'Origem do produto de assinatura; KPIs Wagoo filtram produto = wagoo.';

-- Séries diárias agregadas (Wagoo: preencher via job/webhook de billing; opcional para core)
create table if not exists public.dashboard_daily_app_metrics (
  bucket_date date not null,
  app text not null check (app in ('wagoo', '2avendas', 'core')),
  revenue numeric(14, 2) not null default 0,
  transactions bigint not null default 0,
  primary key (bucket_date, app)
);

comment on table public.dashboard_daily_app_metrics is 'Receita/transações por dia e app. Wagoo: ingestão externa. 2AVENDAS no gráfico usa pedidos em tempo real; esta tabela pode complementar KPIs de receita Wagoo.';

alter table public.dashboard_daily_app_metrics enable row level security;

revoke all on table public.dashboard_daily_app_metrics from anon, authenticated;
grant select, insert, update, delete on table public.dashboard_daily_app_metrics to service_role;

-- Amostras de uptime diário (média do período no KPI). Sem linhas → API usa fallback 99.92.
create table if not exists public.dashboard_system_health (
  day date primary key,
  uptime_pct numeric(5, 2) not null check (uptime_pct >= 0 and uptime_pct <= 100)
);

comment on table public.dashboard_system_health is 'Registrar uptime% por dia (probe externo ou cron).';

alter table public.dashboard_system_health enable row level security;

revoke all on table public.dashboard_system_health from anon, authenticated;
grant select, insert, update, delete on table public.dashboard_system_health to service_role;

-- Eventos recentes para tabela “live” do dashboard
create table if not exists public.dashboard_app_logs (
  id uuid primary key default gen_random_uuid (),
  created_at timestamptz not null default now(),
  app text not null check (app in ('wagoo', '2avendas', 'core')),
  mensagem text not null,
  status text not null check (status in ('online', 'degraded', 'offline'))
);

create index if not exists dashboard_app_logs_created_at_idx on public.dashboard_app_logs (created_at desc);

comment on table public.dashboard_app_logs is 'Linhas de status dos sub-apps (wagoo, 2avendas, core). Alimentar via worker ou triggers.';

alter table public.dashboard_app_logs enable row level security;

revoke all on table public.dashboard_app_logs from anon, authenticated;
grant select, insert, update, delete on table public.dashboard_app_logs to service_role;

-- Payload único para o dashboard executivo
create or replace function public.dashboard_full_payload(
  p_organization_id uuid default null,
  p_period_days integer default 30,
  p_chart_days integer default 14
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_today date := (v_now at time zone 'utc')::date;
  v_cur_start timestamptz := v_now - make_interval(days => greatest(coalesce(p_period_days, 30), 1));
  v_prev_start timestamptz := v_now - make_interval(days => greatest(coalesce(p_period_days, 30), 1) * 2);
  v_prev_end timestamptz := v_cur_start;
  v_cd integer := greatest(coalesce(p_chart_days, 14), 1);

  rev_w_cur numeric := 0;
  rev_w_prev numeric := 0;
  rev_o_cur numeric := 0;
  rev_o_prev numeric := 0;
  rev_tot_cur numeric;
  rev_tot_prev numeric;
  rev_pct numeric;

  sub_cur bigint := 0;
  sub_then bigint := 0;
  sub_pct numeric;

  vol_cur bigint := 0;
  vol_prev bigint := 0;
  vol_pct numeric;

  uptime_val numeric;

  wagoo_chart jsonb;
  av_chart jsonb;
  logs jsonb;
begin
  select coalesce(sum(revenue), 0) into rev_w_cur
  from dashboard_daily_app_metrics m
  where m.app = 'wagoo'
    and m.bucket_date >= (v_cur_start at time zone 'utc')::date
    and m.bucket_date <= v_today;

  select coalesce(sum(revenue), 0) into rev_w_prev
  from dashboard_daily_app_metrics m
  where m.app = 'wagoo'
    and m.bucket_date >= (v_prev_start at time zone 'utc')::date
    and m.bucket_date < (v_prev_end at time zone 'utc')::date;

  select coalesce(sum(o.total), 0) into rev_o_cur
  from orders o
  where (p_organization_id is null or o.organization_id = p_organization_id)
    and o.created_at >= v_cur_start
    and o.created_at <= v_now
    and o.status <> 'cancelado';

  select coalesce(sum(o.total), 0) into rev_o_prev
  from orders o
  where (p_organization_id is null or o.organization_id = p_organization_id)
    and o.created_at >= v_prev_start
    and o.created_at < v_prev_end
    and o.status <> 'cancelado';

  rev_tot_cur := rev_w_cur + rev_o_cur;
  rev_tot_prev := rev_w_prev + rev_o_prev;
  rev_pct :=
    case
      when rev_tot_prev > 0 then round(((rev_tot_cur - rev_tot_prev) / rev_tot_prev * 100)::numeric, 2)
      else null
    end;

  select count(*) into sub_cur
  from assinaturas a
  where a.status = 'ativa'
    and a.produto = 'wagoo'
    and (p_organization_id is null or a.organization_id = p_organization_id);

  select count(*) into sub_then
  from assinaturas a
  where a.status = 'ativa'
    and a.produto = 'wagoo'
    and (p_organization_id is null or a.organization_id = p_organization_id)
    and a.created_at <= v_cur_start;

  sub_pct :=
    case
      when sub_then > 0 then round((((sub_cur - sub_then)::numeric / sub_then::numeric) * 100)::numeric, 2)
      else null
    end;

  select count(*) into vol_cur
  from orders o
  where (p_organization_id is null or o.organization_id = p_organization_id)
    and o.created_at >= v_cur_start
    and o.created_at <= v_now
    and o.status <> 'cancelado';

  select count(*) into vol_prev
  from orders o
  where (p_organization_id is null or o.organization_id = p_organization_id)
    and o.created_at >= v_prev_start
    and o.created_at < v_prev_end
    and o.status <> 'cancelado';

  vol_pct :=
    case
      when vol_prev > 0 then round((((vol_cur - vol_prev)::numeric / vol_prev::numeric) * 100)::numeric, 2)
      else null
    end;

  select coalesce(
    (
      select round(avg(uptime_pct)::numeric, 2)
      from dashboard_system_health h
      where h.day >= v_today - greatest(coalesce(p_period_days, 30), 1)
    ),
    99.92::numeric
  ) into uptime_val;

  with dias as (
    select (v_today - ((v_cd - 1) - gs.i))::date as dia
    from generate_series(0, v_cd - 1) as gs(i)
  )
  select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'dia',
          to_char(dias.dia, 'YYYY-MM-DD'),
          'valor_reais',
          coalesce(m.revenue, 0)::numeric
        )
        order by dias.dia
      ),
      '[]'::jsonb
    )
  into wagoo_chart
  from dias
  left join dashboard_daily_app_metrics m on m.bucket_date = dias.dia and m.app = 'wagoo';

  with dias as (
    select (v_today - ((v_cd - 1) - gs.i))::date as dia
    from generate_series(0, v_cd - 1) as gs(i)
  ),
  oc as (
    select (o.created_at at time zone 'utc')::date as d,
      count(*)::bigint as transacoes
    from orders o
    where (p_organization_id is null or o.organization_id = p_organization_id)
      and o.status <> 'cancelado'
      and (o.created_at at time zone 'utc')::date >= v_today - (v_cd - 1)
      and (o.created_at at time zone 'utc')::date <= v_today
    group by 1
  )
  select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'dia',
          to_char(dias.dia, 'YYYY-MM-DD'),
          'transacoes',
          coalesce(oc.transacoes, 0::bigint)
        )
        order by dias.dia
      ),
      '[]'::jsonb
    )
  into av_chart
  from dias
  left join oc on oc.d = dias.dia;

  select coalesce(
      jsonb_agg(ob order by ts desc),
      '[]'::jsonb
    )
  into logs
  from (
      select jsonb_build_object(
          'timestamp',
          l.created_at,
          'app',
          l.app,
          'mensagem',
          l.mensagem,
          'status',
          l.status
        ) as ob,
        l.created_at as ts
      from dashboard_app_logs l
      order by l.created_at desc
      limit 50
    ) q;

  return jsonb_build_object(
    'gerado_em',
    to_jsonb(v_now),
    'filtros',
    jsonb_build_object(
      'organization_id',
      to_jsonb(p_organization_id),
      'periodo_dias',
      p_period_days,
      'grafico_dias',
      p_chart_days
    ),
    'kpis',
    jsonb_build_object(
      'receita_total',
      jsonb_build_object('valor_reais', rev_tot_cur, 'variacao_pct', to_jsonb(rev_pct)),
      'assinaturas_ativas_wagoo',
      jsonb_build_object('valor', sub_cur, 'variacao_pct', to_jsonb(sub_pct)),
      'volume_vendas_2avendas',
      jsonb_build_object('valor', vol_cur, 'variacao_pct', to_jsonb(vol_pct)),
      'uptime_medio',
      jsonb_build_object('valor_pct', uptime_val)
    ),
    'wagoo',
    jsonb_build_object(
      'assinaturas_ativas',
      sub_cur,
      'receita_por_dia',
      wagoo_chart,
      'nota',
      'Receita Wagoo usa dashboard_daily_app_metrics (app=wagoo); sem dados a série vem zerada.'
    ),
    'dois_avendas',
    jsonb_build_object(
      'volume_pedidos_periodo',
      vol_cur,
      'volume_por_dia',
      av_chart
    ),
    'eventos_recentes',
    logs,
    'ui',
    jsonb_build_object(
      'sidebar_itens',
      jsonb_build_array(
        jsonb_build_object('id', 'overview', 'label', 'Visão Geral'),
        jsonb_build_object('id', 'wagoo', 'label', 'Wagoo'),
        jsonb_build_object('id', '2avendas', 'label', '2AVENDAS'),
        jsonb_build_object('id', 'settings', 'label', 'Configurações')
      ),
      'topbar',
      jsonb_build_object(
        'mostrar_seletor_organizacao',
        true,
        'mostrar_filtro_periodo',
        true
      ),
      'graficos',
      jsonb_build_object(
        'wagoo',
        jsonb_build_object('tipo', 'area', 'titulo_sugerido', format('Receita / %sd', v_cd)),
        'dois_avendas',
        jsonb_build_object('tipo', 'barra', 'titulo_sugerido', format('Volume / 2AVENDAS (%s dias)', v_cd))
      ),
      'eventos',
      jsonb_build_object(
        'status_para_badge',
        jsonb_build_object(
          'online',
          jsonb_build_object('cor_sugerida', 'branco'),
          'degraded',
          jsonb_build_object('cor_sugerida', 'amarelo'),
          'offline',
          jsonb_build_object('cor_sugerida', 'vermelho_neon', 'animacao_sugerida', 'pulse')
        )
      )
    )
  );
end;
$$;

revoke all on function public.dashboard_full_payload(uuid, integer, integer) from public;
grant execute on function public.dashboard_full_payload(uuid, integer, integer) to service_role;

-- Seeds opcionais (uma vez, se a tabela estiver vazia)
insert into public.dashboard_app_logs (app, mensagem, status)
select *
from (
    values
      ('core', 'Núcleo do dashboard: aguardando ingestão de logs reais.', 'online'::text),
      ('wagoo', 'Conector Wagoo: configure ingestão de receita diária.', 'degraded'::text),
      ('2avendas', 'Pedidos 2AVENDAS sincronizados com Postgres.', 'online'::text)
  ) v(app, mensagem, status)
where not exists (select 1 from public.dashboard_app_logs);
