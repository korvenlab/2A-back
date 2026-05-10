-- Registro de disparos por e-mail / WhatsApp (templates enviados pelo próprio usuário via cliente externo).

create table if not exists public.sales_outreach_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  channel text not null,
  summary text not null,
  body text,
  customer_id uuid references public.customers (id) on delete set null,
  opportunity_id uuid references public.sales_opportunities (id) on delete set null,
  budget_id uuid references public.budgets (id) on delete set null,
  order_id uuid references public.orders (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint sales_outreach_events_channel_chk check (channel in ('email', 'whatsapp'))
);

create index if not exists idx_sales_outreach_org_created
  on public.sales_outreach_events (organization_id, created_at desc);

create index if not exists idx_sales_outreach_customer
  on public.sales_outreach_events (customer_id);

alter table public.sales_outreach_events enable row level security;

drop policy if exists "Staff reads org outreach" on public.sales_outreach_events;
create policy "Staff reads org outreach"
on public.sales_outreach_events
for select
to authenticated
using (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

drop policy if exists "Staff inserts org outreach" on public.sales_outreach_events;
create policy "Staff inserts org outreach"
on public.sales_outreach_events
for insert
to authenticated
with check (
  organization_id = current_user_org()
  and (
    has_role(auth.uid(), 'admin'::public.app_role)
    or has_role(auth.uid(), 'vendedor'::public.app_role)
  )
);

grant select, insert on table public.sales_outreach_events to authenticated;

create or replace function public.trg_sales_outreach_set_created_by()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.created_by is null then
    new.created_by := auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sales_outreach_bi on public.sales_outreach_events;
create trigger trg_sales_outreach_bi
before insert on public.sales_outreach_events
for each row execute function public.trg_sales_outreach_set_created_by();
