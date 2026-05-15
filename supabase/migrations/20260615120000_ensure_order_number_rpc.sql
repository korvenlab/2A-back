-- Corrige pedidos com order_number 0/null (ex.: trigger ausente ou default antigo).
-- Reanexa BEFORE INSERT para projetos em que o trigger tenha sido perdido.

create or replace function public.ensure_order_number(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_customer uuid;
  v_cur integer;
  v_next integer;
begin
  select organization_id, customer_id, coalesce(order_number, 0)
    into v_org, v_customer, v_cur
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Pedido não encontrado';
  end if;

  if not (
    v_org is not distinct from public.current_user_org()
    or exists (
      select 1 from public.customers c
      where c.id = v_customer
        and c.user_id = auth.uid()
    )
  ) then
    raise exception 'Sem permissão para este pedido' using errcode = '42501';
  end if;

  if v_cur > 0 then
    return v_cur;
  end if;

  perform pg_advisory_xact_lock(
    9123847,
    hashtext(coalesce(v_org::text, ''))
  );

  select coalesce(max(order_number), 0) + 1
    into v_next
  from public.orders
  where organization_id = v_org;

  update public.orders
  set order_number = v_next
  where id = p_order_id
    and (order_number is null or order_number <= 0);

  return v_next;
end;
$$;

comment on function public.ensure_order_number(uuid) is
  'Atribui order_number quando ficou 0/null; mesmo advisory lock que set_order_number.';

grant execute on function public.ensure_order_number(uuid) to authenticated;

drop trigger if exists trg_set_order_number on public.orders;

create trigger trg_set_order_number
  before insert on public.orders
  for each row execute function public.set_order_number();
