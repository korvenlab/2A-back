-- Estoque: baixa/restauração ao mudar status do pedido ou inserir itens em pedido já "consumindo" estoque.
-- NF-e: campos manuais (chave/data) até integração SEFAZ.
-- Visitas comerciais.

-- Projetos bootstrap sem migrações antigas podem não ter esta função (visitas / outros triggers).
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

alter table public.order_items
  add column if not exists stock_applied boolean not null default false;

alter table public.orders
  add column if not exists nfe_key text null,
  add column if not exists nfe_issued_at timestamptz null;

comment on column public.orders.nfe_key is 'Chave da NF-e emitida externamente (manual); integração SEFAZ futura.';
comment on column public.order_items.stock_applied is 'True quando a baixa de estoque já foi aplicada para esta linha.';

-- ---------- Funções de estoque ----------

create or replace function public.order_status_consumes_stock(st public.order_status)
returns boolean
language sql
immutable
as $$
  select st in ('enviado'::public.order_status, 'aprovado'::public.order_status, 'faturado'::public.order_status);
$$;

create or replace function public.apply_stock_for_order_lines(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  new_stock int;
  pname text;
begin
  for r in
    select oi.id, oi.product_id, oi.quantity, oi.stock_applied
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.product_id is not null
      and coalesce(oi.stock_applied, false) = false
  loop
    select stock, name into new_stock, pname
    from public.products
    where id = r.product_id
    for update;

    if new_stock is null then
      raise exception 'Produto não encontrado para baixa de estoque.';
    end if;

    if new_stock < r.quantity then
      raise exception 'Estoque insuficiente para "%" (disponível %, pedido %).', pname, new_stock, r.quantity;
    end if;

    update public.products
      set stock = stock - r.quantity
      where id = r.product_id;

    update public.order_items
      set stock_applied = true
      where id = r.id;
  end loop;
end;
$$;

create or replace function public.restore_stock_for_order_lines(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  for r in
    select oi.id, oi.product_id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.product_id is not null
      and coalesce(oi.stock_applied, false) = true
  loop
    update public.products
      set stock = stock + r.quantity
      where id = r.product_id;

    update public.order_items
      set stock_applied = false
      where id = r.id;
  end loop;
end;
$$;

-- Novo item em pedido que já consome estoque: baixa imediata.
create or replace function public.trg_order_items_stock_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ost public.order_status;
begin
  select o.status into ost from public.orders o where o.id = new.order_id;
  if public.order_status_consumes_stock(ost) and new.product_id is not null and coalesce(new.stock_applied, false) = false then
    perform public.apply_stock_for_order_lines(new.order_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_order_items_stock_after_insert on public.order_items;
create trigger trg_order_items_stock_after_insert
  after insert on public.order_items
  for each row execute function public.trg_order_items_stock_after_insert();

-- Mudança de status: entra no fluxo que consome / sai ou cancela.
create or replace function public.trg_orders_stock_after_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_c boolean;
  new_c boolean;
begin
  if tg_op <> 'UPDATE' or old.status is not distinct from new.status then
    return new;
  end if;

  old_c := public.order_status_consumes_stock(old.status);
  new_c := public.order_status_consumes_stock(new.status);

  if new_c and not old_c then
    perform public.apply_stock_for_order_lines(new.id);
  elsif old_c and not new_c then
    perform public.restore_stock_for_order_lines(new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_orders_stock_after_status on public.orders;
create trigger trg_orders_stock_after_status
  after update of status on public.orders
  for each row execute function public.trg_orders_stock_after_status();

-- Exclusão do pedido: devolver estoque antes do CASCADE apagar itens.
create or replace function public.trg_orders_stock_before_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.restore_stock_for_order_lines(old.id);
  return old;
end;
$$;

drop trigger if exists trg_orders_stock_before_delete on public.orders;
create trigger trg_orders_stock_before_delete
  before delete on public.orders
  for each row execute function public.trg_orders_stock_before_delete();

-- ---------- Visitas comerciais ----------

create table if not exists public.commercial_visits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid references public.customers (id) on delete set null,
  seller_id uuid references auth.users (id) on delete set null,
  scheduled_at timestamptz not null,
  duration_minutes integer not null default 60,
  status text not null default 'agendada',
  notes text,
  address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint commercial_visits_status_chk check (status in ('agendada', 'realizada', 'cancelada')),
  constraint commercial_visits_duration_chk check (duration_minutes > 0 and duration_minutes <= 24 * 60)
);

create index if not exists idx_commercial_visits_org_scheduled
  on public.commercial_visits (organization_id, scheduled_at);

create index if not exists idx_commercial_visits_customer
  on public.commercial_visits (customer_id);

alter table public.commercial_visits enable row level security;

drop policy if exists "Staff views org visits" on public.commercial_visits;
create policy "Staff views org visits"
on public.commercial_visits
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff manages org visits" on public.commercial_visits;
create policy "Staff manages org visits"
on public.commercial_visits
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

grant select, insert, update, delete on table public.commercial_visits to authenticated;

drop trigger if exists trg_commercial_visits_updated on public.commercial_visits;
create trigger trg_commercial_visits_updated
  before update on public.commercial_visits
  for each row execute function public.touch_updated_at();
