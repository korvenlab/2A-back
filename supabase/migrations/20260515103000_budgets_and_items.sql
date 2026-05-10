-- Orçamentos comerciais (admin / vendedor): cabeçalho, itens com descontos encadeados D1–D7.

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  budget_number integer not null default 0,
  customer_id uuid not null references public.customers (id) on delete restrict,
  buyer_role text not null default 'gerente_compras',
  seller_id uuid references auth.users (id) on delete set null,
  quote_date date not null default ((timezone('utc', now()))::date),
  carrier text,
  freight_type text not null default 'cif',
  delivery_forecast date,
  notes_public text,
  notes_private text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,
  constraint budgets_freight_chk check (freight_type in ('cif', 'fob')),
  constraint budgets_org_number_unique unique (organization_id, budget_number)
);

create index idx_budgets_org on public.budgets (organization_id);
create index idx_budgets_customer on public.budgets (customer_id);
create index idx_budgets_seller on public.budgets (seller_id);

create or replace function public.set_budget_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.budget_number is null or new.budget_number = 0 then
    select coalesce(max(budget_number), 0) + 1
      into new.budget_number
    from public.budgets
    where organization_id = new.organization_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_budget_number on public.budgets;
create trigger trg_set_budget_number
before insert on public.budgets
for each row
execute function public.set_budget_number();

create table public.budget_items (
  id uuid primary key default gen_random_uuid(),
  budget_id uuid not null references public.budgets (id) on delete cascade,
  line_order integer not null default 0,
  product_id uuid references public.products (id) on delete set null,
  code text,
  description text not null default '',
  supplier_brand text,
  commission_pct numeric(12, 4) not null default 0,
  list_price numeric(14, 4) not null default 0,
  discount_d1 numeric(8, 4) not null default 0,
  discount_d2 numeric(8, 4) not null default 0,
  discount_d3 numeric(8, 4) not null default 0,
  discount_d4 numeric(8, 4) not null default 0,
  discount_d5 numeric(8, 4) not null default 0,
  discount_d6 numeric(8, 4) not null default 0,
  discount_d7 numeric(8, 4) not null default 0,
  unit_price_final numeric(14, 4) not null default 0,
  quantity numeric(14, 4) not null default 1,
  weight_gross_kg numeric(14, 4),
  weight_net_kg numeric(14, 4),
  ipi_amount numeric(14, 4) not null default 0,
  st_amount numeric(14, 4) not null default 0,
  created_at timestamptz not null default now()
);

create index idx_budget_items_budget on public.budget_items (budget_id);

alter table public.budgets enable row level security;
alter table public.budget_items enable row level security;

drop policy if exists "Staff views all budgets" on public.budgets;
drop policy if exists "Staff manages all budgets" on public.budgets;

create policy "Staff views all budgets"
on public.budgets
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

create policy "Staff manages all budgets"
on public.budgets
for all
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
)
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff manages budget items" on public.budget_items;

create policy "Staff manages budget items"
on public.budget_items
for all
to authenticated
using (
  exists (
    select 1
    from public.budgets b
    where b.id = budget_items.budget_id
      and b.organization_id = current_user_org()
      and (
        has_role(auth.uid(), 'admin'::public.app_role)
        or has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
)
with check (
  exists (
    select 1
    from public.budgets b
    where b.id = budget_items.budget_id
      and b.organization_id = current_user_org()
      and (
        has_role(auth.uid(), 'admin'::public.app_role)
        or has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
);

grant select, insert, update, delete on table public.budgets to authenticated;
grant select, insert, update, delete on table public.budget_items to authenticated;
