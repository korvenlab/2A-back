-- Vendedor enxerga (somente leitura) o convite universal de catálogo da própria empresa,
-- para copiar o mesmo link/token que o administrador usa.

drop policy if exists "Vendedor reads universal client catalog invite" on public.seller_invitations;

create policy "Vendedor reads universal client catalog invite"
on public.seller_invitations
for select
to authenticated
using (
  public.has_role(auth.uid(), 'vendedor'::public.app_role)
  and organization_id = public.current_user_org()
  and purpose = 'client_catalog'
  and lower(trim(email)) = lower(public.universal_client_catalog_invite_email())
);
