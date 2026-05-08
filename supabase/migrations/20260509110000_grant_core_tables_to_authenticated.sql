-- PostgREST / Supabase client precisa de privilégio à nível de tabela **além** do RLS.
-- Várias tabelas criadas nos migrations iniciais não receberam GRANT para `authenticated`,
-- o que resulta em 42501 "permission denied for relation …" e no toast genérico no app.

grant usage on schema public to authenticated;

grant select, update on table public.organizations to authenticated;

grant select, insert, update on table public.profiles to authenticated;

grant select, insert, update, delete on table public.seller_invitations to authenticated;

-- Idempotente com migrations anteriores (reforço explícito)
grant select, insert, update, delete on table public.customers to authenticated;
grant select, insert, update, delete on table public.products to authenticated;
grant select, insert, update, delete on table public.orders to authenticated;
grant select, insert, update, delete on table public.order_items to authenticated;

grant select on table public.app_users to authenticated;
grant select on table public.user_roles to authenticated;
