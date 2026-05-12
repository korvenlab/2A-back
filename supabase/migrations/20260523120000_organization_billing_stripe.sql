-- Billing: Stripe subscription + unlock manual (Korven Dashboard).
alter table public.organizations
  add column if not exists stripe_customer_id text,
  add column if not exists stripe_subscription_id text,
  add column if not exists billing_stripe_active boolean not null default false,
  add column if not exists billing_manual_unlock boolean not null default false;

comment on column public.organizations.stripe_customer_id is 'Stripe Customer id (cus_...)';
comment on column public.organizations.stripe_subscription_id is 'Stripe Subscription id (sub_...)';
comment on column public.organizations.billing_stripe_active is 'True quando assinatura Stripe está ativa (webhook).';
comment on column public.organizations.billing_manual_unlock is 'Override manual via Korven Dashboard (API com segredo).';

-- Representações já existentes continuam com acesso; novas linhas seguem default false/false.
update public.organizations
set billing_manual_unlock = true
where billing_manual_unlock = false
  and billing_stripe_active = false;
