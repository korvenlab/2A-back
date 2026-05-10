-- Funil de vendas (CRM): estágios por organização, oportunidades ligadas a clientes e produtos, histórico de estágio.

-- ---------- estágios customizáveis ----------
create table public.pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pipeline_stages_org_name_unique unique (organization_id, name)
);

create index idx_pipeline_stages_org_sort on public.pipeline_stages (organization_id, sort_order);

-- ---------- oportunidade (negócio) ----------
create table public.sales_opportunities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete restrict,
  stage_id uuid not null references public.pipeline_stages (id) on delete restrict,
  title text not null,
  owner_id uuid references auth.users (id) on delete set null,
  expected_close_date date,
  priority integer not null default 0,
  notes text,
  value_total numeric(14, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_sales_opportunities_org on public.sales_opportunities (organization_id);
create index idx_sales_opportunities_stage on public.sales_opportunities (stage_id);
create index idx_sales_opportunities_customer on public.sales_opportunities (customer_id);
create index idx_sales_opportunities_owner on public.sales_opportunities (owner_id);

-- ---------- produtos na oportunidade ----------
create table public.opportunity_products (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.sales_opportunities (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete restrict,
  quantity numeric(14, 4) not null default 1,
  unit_price numeric(14, 4) not null default 0,
  line_total numeric(14, 4) generated always as (quantity * unit_price) stored,
  created_at timestamptz not null default now()
);

create index idx_opportunity_products_opp on public.opportunity_products (opportunity_id);

-- ---------- histórico de mudança de estágio ----------
create table public.opportunity_stage_events (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.sales_opportunities (id) on delete cascade,
  from_stage_id uuid references public.pipeline_stages (id) on delete set null,
  to_stage_id uuid not null references public.pipeline_stages (id) on delete set null,
  changed_by uuid references auth.users (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index idx_opportunity_stage_events_opp on public.opportunity_stage_events (opportunity_id, created_at desc);

-- ---------- valores totais ----------
create or replace function public.refresh_opportunity_value_total(p_opportunity_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_sum numeric(14, 2);
begin
  select coalesce(round(sum(line_total)::numeric, 2), 0)
    into v_sum
  from public.opportunity_products
  where opportunity_id = p_opportunity_id;

  update public.sales_opportunities
  set value_total = v_sum,
      updated_at = now()
  where id = p_opportunity_id;
end;
$$;

create or replace function public.trg_opportunity_products_touch_total()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
begin
  if tg_op = 'DELETE' then
    v_id := old.opportunity_id;
  else
    v_id := new.opportunity_id;
  end if;
  perform public.refresh_opportunity_value_total(v_id);
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_opportunity_products_touch_total on public.opportunity_products;
create trigger trg_opportunity_products_touch_total
after insert or update or delete on public.opportunity_products
for each row
execute function public.trg_opportunity_products_touch_total();

create or replace function public.touch_pipeline_tables_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_pipeline_stages_updated on public.pipeline_stages;
create trigger trg_pipeline_stages_updated
before update on public.pipeline_stages
for each row
execute function public.touch_pipeline_tables_updated_at();

create or replace function public.touch_sales_opportunities_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_sales_opportunities_updated on public.sales_opportunities;
create trigger trg_sales_opportunities_updated
before update on public.sales_opportunities
for each row
execute function public.touch_sales_opportunities_updated_at();

-- ---------- estágios padrão para novas organizações ----------
create or replace function public.seed_default_pipeline_stages_for_org()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.pipeline_stages (organization_id, name, sort_order, color)
  values
    (new.id, 'Prospecção', 10, '#64748b'),
    (new.id, 'Qualificação', 20, '#0ea5e9'),
    (new.id, 'Proposta', 30, '#a855f7'),
    (new.id, 'Negociação', 40, '#f97316'),
    (new.id, 'Fechamento', 50, '#22c55e');
  return new;
end;
$$;

drop trigger if exists trg_org_seed_pipeline on public.organizations;
create trigger trg_org_seed_pipeline
after insert on public.organizations
for each row
execute function public.seed_default_pipeline_stages_for_org();

-- ---------- seed retroativo para organizações existentes ----------
insert into public.pipeline_stages (organization_id, name, sort_order, color)
select o.id, v.name, v.sort_order, v.color
from public.organizations o
cross join (
  values
    ('Prospecção', 10, '#64748b'),
    ('Qualificação', 20, '#0ea5e9'),
    ('Proposta', 30, '#a855f7'),
    ('Negociação', 40, '#f97316'),
    ('Fechamento', 50, '#22c55e')
) as v(name, sort_order, color)
where not exists (
  select 1 from public.pipeline_stages ps where ps.organization_id = o.id
);

-- ---------- RPC: mover estágio com histórico + observação ----------
create or replace function public.advance_sales_opportunity(
  p_opportunity_id uuid,
  p_to_stage_id uuid,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_from uuid;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  select o.organization_id, o.stage_id
    into v_org, v_from
  from public.sales_opportunities o
  where o.id = p_opportunity_id
  for update;

  if v_org is null then
    raise exception 'Oportunidade não encontrada';
  end if;

  if v_org <> public.current_user_org() then
    raise exception 'Organização inválida';
  end if;

  if not (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    or public.has_role(auth.uid(), 'vendedor'::public.app_role)
  ) then
    raise exception 'Sem permissão';
  end if;

  if not exists (
    select 1
    from public.pipeline_stages s
    where s.id = p_to_stage_id
      and s.organization_id = v_org
  ) then
    raise exception 'Estágio inválido para esta organização';
  end if;

  if v_from is not distinct from p_to_stage_id then
    return;
  end if;

  update public.sales_opportunities
  set stage_id = p_to_stage_id,
      updated_at = now()
  where id = p_opportunity_id;

  insert into public.opportunity_stage_events (
    opportunity_id,
    from_stage_id,
    to_stage_id,
    changed_by,
    note
  )
  values (
    p_opportunity_id,
    v_from,
    p_to_stage_id,
    auth.uid(),
    nullif(trim(p_note), '')
  );
end;
$$;

grant execute on function public.advance_sales_opportunity(uuid, uuid, text) to authenticated;

-- ---------- RLS ----------
alter table public.pipeline_stages enable row level security;
alter table public.sales_opportunities enable row level security;
alter table public.opportunity_products enable row level security;
alter table public.opportunity_stage_events enable row level security;

drop policy if exists "Staff manages pipeline stages" on public.pipeline_stages;
create policy "Staff manages pipeline stages"
on public.pipeline_stages
for all
to authenticated
using (
  organization_id = public.current_user_org()
  and (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    or public.has_role(auth.uid(), 'vendedor'::public.app_role)
  )
)
with check (
  organization_id = public.current_user_org()
  and (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    or public.has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff manages opportunities" on public.sales_opportunities;
create policy "Staff manages opportunities"
on public.sales_opportunities
for all
to authenticated
using (
  organization_id = public.current_user_org()
  and (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    or public.has_role(auth.uid(), 'vendedor'::public.app_role)
  )
)
with check (
  organization_id = public.current_user_org()
  and (
    public.has_role(auth.uid(), 'admin'::public.app_role)
    or public.has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff manages opportunity products" on public.opportunity_products;
create policy "Staff manages opportunity products"
on public.opportunity_products
for all
to authenticated
using (
  exists (
    select 1
    from public.sales_opportunities o
    where o.id = opportunity_products.opportunity_id
      and o.organization_id = public.current_user_org()
      and (
        public.has_role(auth.uid(), 'admin'::public.app_role)
        or public.has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
)
with check (
  exists (
    select 1
    from public.sales_opportunities o
    where o.id = opportunity_products.opportunity_id
      and o.organization_id = public.current_user_org()
      and (
        public.has_role(auth.uid(), 'admin'::public.app_role)
        or public.has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
);

drop policy if exists "Staff reads opportunity stage events" on public.opportunity_stage_events;
create policy "Staff reads opportunity stage events"
on public.opportunity_stage_events
for select
to authenticated
using (
  exists (
    select 1
    from public.sales_opportunities o
    where o.id = opportunity_stage_events.opportunity_id
      and o.organization_id = public.current_user_org()
      and (
        public.has_role(auth.uid(), 'admin'::public.app_role)
        or public.has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
);

drop policy if exists "Staff inserts opportunity stage events" on public.opportunity_stage_events;
create policy "Staff inserts opportunity stage events"
on public.opportunity_stage_events
for insert
to authenticated
with check (
  exists (
    select 1
    from public.sales_opportunities o
    where o.id = opportunity_stage_events.opportunity_id
      and o.organization_id = public.current_user_org()
      and (
        public.has_role(auth.uid(), 'admin'::public.app_role)
        or public.has_role(auth.uid(), 'vendedor'::public.app_role)
      )
  )
);

grant select, insert, update, delete on table public.pipeline_stages to authenticated;
grant select, insert, update, delete on table public.sales_opportunities to authenticated;
grant select, insert, update, delete on table public.opportunity_products to authenticated;
grant select, insert on table public.opportunity_stage_events to authenticated;
