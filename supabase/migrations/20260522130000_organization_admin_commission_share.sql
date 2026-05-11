-- Participação do administrador sobre a comissão bruta calculada para cada vendedor (0–100%).

alter table public.organizations
  add column if not exists admin_commission_share_pct numeric(7, 4) not null default 0
    check (admin_commission_share_pct >= 0 and admin_commission_share_pct <= 100);

comment on column public.organizations.admin_commission_share_pct is
  'Percentual da comissão de cada vendedor (sobre o total do pedido) que a representação retém para o administrador.';
