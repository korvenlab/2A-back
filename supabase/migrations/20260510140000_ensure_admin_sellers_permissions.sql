-- Garante que o papel admin tenha permissões de equipe/vendedores quando a matriz foi criada antes do catálogo completo.
insert into public.app_role_permissions (role_slug, permission)
values
  ('admin', 'sellers:view'),
  ('admin', 'sellers:manage')
on conflict (role_slug, permission) do nothing;
