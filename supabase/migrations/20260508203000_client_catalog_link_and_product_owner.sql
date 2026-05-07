-- seller_invitations agora também serve como link de catálogo para cliente
alter table public.seller_invitations
  add column if not exists purpose text not null default 'seller_signup';

alter table public.seller_invitations
  drop constraint if exists seller_invitations_purpose_check;

alter table public.seller_invitations
  add constraint seller_invitations_purpose_check
  check (purpose in ('seller_signup', 'client_catalog'));

create index if not exists idx_seller_invitations_purpose
  on public.seller_invitations (purpose);

-- cada produto fica vinculado ao vendedor que cadastrou
alter table public.products
  add column if not exists owner_seller_id uuid null references auth.users(id) on delete set null;

create index if not exists idx_products_owner_seller
  on public.products (owner_seller_id);
