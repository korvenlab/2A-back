-- Garante código sequencial único por organização quando order_number ficou em 0.

do $$
declare
  r record;
  n int;
begin
  for r in
    select id, organization_id
    from public.orders
    where order_number is null or order_number <= 0
    order by organization_id, created_at, id
  loop
    select coalesce(max(order_number), 0) + 1 into n
    from public.orders
    where organization_id = r.organization_id;
    update public.orders
    set order_number = n
    where id = r.id;
  end loop;
end;
$$;
