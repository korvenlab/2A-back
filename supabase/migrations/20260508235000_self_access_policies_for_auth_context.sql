-- Allow authenticated users to read their own identity and role context.
-- This supports frontend role-aware navigation and permissions refresh.

alter table public.profiles enable row level security;
alter table public.app_users enable row level security;
alter table public.user_roles enable row level security;

grant select on public.profiles to authenticated;
grant select on public.app_users to authenticated;
grant select on public.user_roles to authenticated;

drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile"
on public.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists "Users read own app_user row" on public.app_users;
create policy "Users read own app_user row"
on public.app_users
for select
to authenticated
using (id = auth.uid() and deleted_at is null);

drop policy if exists "Users read own role rows" on public.user_roles;
create policy "Users read own role rows"
on public.user_roles
for select
to authenticated
using (user_id = auth.uid());
