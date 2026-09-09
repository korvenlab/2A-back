-- Durable control-plane event outbox and idempotent command receipts.
create table if not exists public.dashboard_event_outbox (
  id uuid primary key default gen_random_uuid(),
  event jsonb not null,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  delivered_at timestamptz null,
  last_error text null,
  created_at timestamptz not null default now(),
  constraint dashboard_event_outbox_event_shape check (
    event ? 'event_id'
    and event ? 'event_type'
    and event ? 'occurred_at'
    and event ? 'product'
    and event ? 'external_user_id'
    and event ? 'payload'
  )
);

create index if not exists dashboard_event_outbox_pending_idx
  on public.dashboard_event_outbox (next_attempt_at, created_at)
  where delivered_at is null;

alter table public.dashboard_event_outbox enable row level security;
revoke all on table public.dashboard_event_outbox from anon, authenticated;
grant select, insert, update, delete on table public.dashboard_event_outbox to service_role;

create table if not exists public.control_plane_command_receipts (
  idempotency_key text primary key,
  command_type text not null,
  request_hash text not null,
  status text not null default 'processing',
  response jsonb null,
  created_at timestamptz not null default now(),
  completed_at timestamptz null,
  constraint control_plane_command_type_check check (
    command_type in ('role.set', 'status.set', 'plan.set', 'access.grant', 'user.delete')
  ),
  constraint control_plane_command_status_check check (status in ('processing', 'completed'))
);

alter table public.control_plane_command_receipts enable row level security;
revoke all on table public.control_plane_command_receipts from anon, authenticated;
grant select, insert, update, delete on table public.control_plane_command_receipts to service_role;

alter table public.app_users
  add column if not exists first_login_published_at timestamptz null;

create or replace function public.enqueue_dashboard_user_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := gen_random_uuid();
begin
  insert into public.dashboard_event_outbox (id, event)
  values (
    v_event_id,
    jsonb_strip_nulls(jsonb_build_object(
      'event_id', v_event_id,
      'event_type', 'user.created',
      'occurred_at', coalesce(new.created_at, now()),
      'product', '2avendas',
      'external_user_id', new.id,
      'organization_id', new.organization_id,
      'email', new.email,
      'payload', jsonb_build_object('role', new.role, 'active', new.active)
    ))
  );
  return new;
end;
$$;

drop trigger if exists trg_enqueue_dashboard_user_created on public.app_users;
create trigger trg_enqueue_dashboard_user_created
after insert on public.app_users
for each row execute function public.enqueue_dashboard_user_created();

create or replace function public.record_dashboard_session(
  p_user_id uuid,
  p_organization_id uuid,
  p_email text,
  p_occurred_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first_login boolean := false;
  v_event_id uuid;
begin
  update public.app_users
  set
    first_login_published_at = coalesce(first_login_published_at, p_occurred_at),
    last_sign_in_at = p_occurred_at,
    updated_at = p_occurred_at
  where id = p_user_id
  returning (first_login_published_at = p_occurred_at) into v_first_login;

  v_event_id := gen_random_uuid();
  insert into public.dashboard_event_outbox (id, event)
  values (
    v_event_id,
    jsonb_strip_nulls(jsonb_build_object(
      'event_id', v_event_id,
      'event_type', 'session.started',
      'occurred_at', p_occurred_at,
      'product', '2avendas',
      'external_user_id', p_user_id,
      'organization_id', p_organization_id,
      'email', p_email,
      'payload', jsonb_build_object('route', '/api/session/menu')
    ))
  );

  if v_first_login then
    v_event_id := gen_random_uuid();
    insert into public.dashboard_event_outbox (id, event)
    values (
      v_event_id,
      jsonb_strip_nulls(jsonb_build_object(
        'event_id', v_event_id,
        'event_type', 'user.first_login',
        'occurred_at', p_occurred_at,
        'product', '2avendas',
        'external_user_id', p_user_id,
        'organization_id', p_organization_id,
        'email', p_email,
        'payload', jsonb_build_object('route', '/api/session/menu')
      ))
    );
  end if;

  return v_first_login;
end;
$$;

revoke all on function public.record_dashboard_session(uuid, uuid, text, timestamptz) from public;
grant execute on function public.record_dashboard_session(uuid, uuid, text, timestamptz) to service_role;
