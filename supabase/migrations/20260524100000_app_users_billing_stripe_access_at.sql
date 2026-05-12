-- Quem pagou no Stripe (Payment Link com client_reference_id org:user): libera só esse app_users.
alter table public.app_users
  add column if not exists billing_stripe_access_at timestamptz null;

comment on column public.app_users.billing_stripe_access_at is
  'Preenchido pelo webhook Stripe quando este usuário conclui pagamento (referência org:user).';
