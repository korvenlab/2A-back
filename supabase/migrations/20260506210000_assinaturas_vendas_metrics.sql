-- Assinaturas (planos/contratos por organização) — alimente esta tabela pelo fluxo de billing ou admin.
create table if not exists public.assinaturas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations (id) on delete cascade,
  plano text,
  valor_mensal numeric(14, 2) not null default 0,
  status text not null default 'ativa',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assinaturas_organization_id_idx on public.assinaturas (organization_id);

alter table public.assinaturas enable row level security;

revoke all on table public.assinaturas from anon, authenticated;
grant select, insert, update, delete on table public.assinaturas to service_role;

-- Vista comercial: vendas = pedidos (orders)
create or replace view public.vendas as
select
  o.id,
  o.organization_id,
  o.customer_id,
  o.order_number,
  o.status::text as status,
  o.total as valor_total,
  o.created_at,
  o.updated_at
from public.orders o;

revoke all on table public.vendas from anon, authenticated;
grant select on table public.vendas to service_role;

-- Agregações para GET /metrics (chamada apenas com service role no backend)
create or replace function public.dashboard_metrics_summary()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'assinaturas',
    jsonb_build_object(
      'quantidade',
      (select count(*)::bigint from public.assinaturas),
      'soma_valor_mensal',
      coalesce((select sum(valor_mensal)::numeric from public.assinaturas), 0)
    ),
    'vendas',
    jsonb_build_object(
      'quantidade',
      (select count(*)::bigint from public.vendas),
      'soma_valor_total',
      coalesce((select sum(valor_total)::numeric from public.vendas), 0)
    ),
    'gerado_em',
    to_jsonb(now())
  );
$$;

revoke all on function public.dashboard_metrics_summary() from public;
grant execute on function public.dashboard_metrics_summary() to service_role;
