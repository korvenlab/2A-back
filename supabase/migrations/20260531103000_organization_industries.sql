-- Indústrias cadastradas por organização (Catálogo) + vínculo opcional em produtos.

create table public.organization_industries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  trade_name text not null,
  responsible_name text not null,
  city text not null,
  state text not null,
  phone text not null,
  email text not null,
  address_line text not null,
  postal_code text not null,
  cnpj text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_organization_industries_org on public.organization_industries (organization_id);
create index idx_organization_industries_org_trade_lower
  on public.organization_industries (organization_id, lower(trade_name));

comment on table public.organization_industries is
  'Cadastro de indústria/fabricante reutilizável nos produtos do catálogo da organização.';

alter table public.organization_industries enable row level security;

drop policy if exists "Staff view org industries" on public.organization_industries;
create policy "Staff view org industries"
on public.organization_industries for select
to authenticated
using (
  organization_id = public.current_user_org()
  and (
    public.has_role (auth.uid(), 'admin'::public.app_role)
    or public.has_role (auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff insert org industries" on public.organization_industries;
create policy "Staff insert org industries"
on public.organization_industries for insert
to authenticated
with check (
  organization_id = public.current_user_org()
  and (
    public.has_role (auth.uid(), 'admin'::public.app_role)
    or public.has_role (auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff update org industries" on public.organization_industries;
create policy "Staff update org industries"
on public.organization_industries for update
to authenticated
using (
  organization_id = public.current_user_org()
  and (
    public.has_role (auth.uid(), 'admin'::public.app_role)
    or public.has_role (auth.uid(), 'vendedor'::public.app_role)
  )
)
with check (
  organization_id = public.current_user_org()
  and (
    public.has_role (auth.uid(), 'admin'::public.app_role)
    or public.has_role (auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff delete org industries" on public.organization_industries;
create policy "Staff delete org industries"
on public.organization_industries for delete
to authenticated
using (
  organization_id = public.current_user_org()
  and (
    public.has_role (auth.uid(), 'admin'::public.app_role)
    or public.has_role (auth.uid(), 'vendedor'::public.app_role)
  )
);

grant select, insert, update, delete on public.organization_industries to authenticated;

drop trigger if exists trg_organization_industries_touch_updated_at on public.organization_industries;
create trigger trg_organization_industries_touch_updated_at
before update on public.organization_industries
for each row execute function public.touch_updated_at ();

alter table public.products
  add column if not exists industry_id uuid references public.organization_industries (id) on delete set null;

create index if not exists idx_products_industry_id on public.products (industry_id);

create or replace function public.products_industry_sync_and_guard ()
returns trigger
language plpgsql
as $$
begin
  if new.industry_id is null then
    return new;
  end if;
  if not exists (
    select 1
    from public.organization_industries oi
    where
      oi.id = new.industry_id
      and oi.organization_id = new.organization_id
  ) then
    raise exception 'A indústria selecionada não pertence a esta organização.';
  end if;
  select nullif(trim(oi.trade_name), '') into new.supplier
  from public.organization_industries oi
  where
    oi.id = new.industry_id;
  return new;
end;
$$;

drop trigger if exists trg_products_industry_sync_and_guard on public.products;
create trigger trg_products_industry_sync_and_guard
before insert or update of industry_id, organization_id on public.products
for each row execute function public.products_industry_sync_and_guard ();
