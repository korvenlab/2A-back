-- Mensagens de feedback / bugs / sugestões (app 2AVendas → painel Korven via 2A-back + API key).

create table if not exists public.feedback_messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references auth.users (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete set null,
  user_email text,
  user_full_name text,
  body text not null,
  constraint feedback_messages_body_len check (
    char_length(trim(body)) >= 5
    and char_length(body) <= 8000
  )
);

create index if not exists idx_feedback_messages_created_at on public.feedback_messages (created_at desc);

comment on table public.feedback_messages is
  'Feedback de usuários autenticados; leitura apenas via service_role / backend com API key.';

alter table public.feedback_messages enable row level security;

revoke all on table public.feedback_messages from public;
grant insert on table public.feedback_messages to authenticated;
grant select, insert, update, delete on table public.feedback_messages to service_role;

create policy "authenticated_insert_own_feedback"
on public.feedback_messages
for insert
to authenticated
with check (
  user_id = auth.uid()
);
