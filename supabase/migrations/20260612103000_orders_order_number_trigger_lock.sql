-- Garante número sequencial por organização mesmo com inserções concorrentes;
-- aceita NEW.order_number nulo ou <= 0 (inclui default 0 do cliente manual).

alter table public.orders
  alter column order_number set default 0;

create or replace function public.set_order_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.order_number is not null and new.order_number > 0 then
    return new;
  end if;

  perform pg_advisory_xact_lock(9123847, hashtext(coalesce(new.organization_id::text, '')));

  select coalesce(max(order_number), 0) + 1
  into new.order_number
  from public.orders
  where organization_id = new.organization_id;

  return new;
end;
$$;
