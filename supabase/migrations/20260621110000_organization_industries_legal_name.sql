-- Razão social da indústria (complementa nome fantasia / trade_name).

alter table public.organization_industries
  add column if not exists legal_name text null;

comment on column public.organization_industries.legal_name is
  'Razão social conforme Receita Federal (preenchimento automático via CNPJ).';
