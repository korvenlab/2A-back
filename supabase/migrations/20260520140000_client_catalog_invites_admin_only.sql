-- Link de cadastro ao catálogo (client_catalog): só o administrador da empresa cria/altera/exclui.
-- Vendedor mantém apenas convites seller_signup com invited_by = próprio usuário.

drop policy if exists "Staff manages client invites" on public.seller_invitations;

create policy "Admin manages organization invitations"
on public.seller_invitations
for all
to authenticated
using (
  public.has_role(auth.uid(), 'admin'::public.app_role)
  and organization_id = public.current_user_org()
)
with check (
  public.has_role(auth.uid(), 'admin'::public.app_role)
  and organization_id = public.current_user_org()
);

create policy "Vendedor manages own seller signup invitations"
on public.seller_invitations
for all
to authenticated
using (
  public.has_role(auth.uid(), 'vendedor'::public.app_role)
  and organization_id = public.current_user_org()
  and purpose = 'seller_signup'
  and invited_by = auth.uid()
)
with check (
  public.has_role(auth.uid(), 'vendedor'::public.app_role)
  and organization_id = public.current_user_org()
  and purpose = 'seller_signup'
  and invited_by = auth.uid()
);
