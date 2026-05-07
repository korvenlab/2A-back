-- Pagamento da assinatura (dashboard / billing)
alter table public.assinaturas
  add column if not exists pago boolean not null default false;

alter table public.assinaturas
  add column if not exists pago_em timestamptz null;

comment on column public.assinaturas.pago is 'Se o valor referente ao plano/período foi quitado.';
comment on column public.assinaturas.pago_em is 'Data/hora em que o pagamento foi confirmado (opcional).';

create index if not exists assinaturas_pago_idx on public.assinaturas (pago);

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
      'quantidade_pagas',
      (select count(*) filter (where pago)::bigint from public.assinaturas),
      'quantidade_nao_pagas',
      (select count(*) filter (where not pago)::bigint from public.assinaturas),
      'soma_valor_mensal',
      coalesce((select sum(valor_mensal)::numeric from public.assinaturas), 0),
      'soma_valor_mensal_pago',
      coalesce((select sum(valor_mensal) filter (where pago)::numeric from public.assinaturas), 0),
      'soma_valor_mensal_pendente',
      coalesce((select sum(valor_mensal) filter (where not pago)::numeric from public.assinaturas), 0)
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
