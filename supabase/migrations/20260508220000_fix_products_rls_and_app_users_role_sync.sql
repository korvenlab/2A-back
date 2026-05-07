-- products: garantir SELECT para staff da org após drop de "View org products"
-- e manter user_roles alinhado a app_users (RLS só usa user_roles / has_role).

-- 1) Política SELECT explícita para admin/vendedor
DROP POLICY IF EXISTS "Staff view org products" ON public.products;

CREATE POLICY "Staff view org products"
ON public.products FOR SELECT
TO authenticated
USING (
  organization_id = current_user_org()
  AND (
    has_role(auth.uid(), 'admin'::app_role)
    OR has_role(auth.uid(), 'vendedor'::app_role)
  )
);

-- 2) Garantir privilégios de papel do PostgREST/Supabase (evita erro 42501).
GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO authenticated;

-- 3) Manter user_roles em sync quando app_users for atualizado (painel usando service_role)
CREATE OR REPLACE FUNCTION public.sync_user_roles_from_app_users()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  slug text := trim(lower(new.role));
  mapped app_role := NULL;
  should_sync boolean := false;
BEGIN
  IF tg_op = 'INSERT' THEN
    should_sync := true;
  ELSIF new.role IS DISTINCT FROM old.role OR new.organization_id IS DISTINCT FROM old.organization_id THEN
    should_sync := true;
  END IF;

  IF should_sync THEN
    IF slug IN ('admin', 'vendedor', 'cliente') THEN
      mapped := slug::app_role;
    END IF;

    IF mapped IS NOT NULL AND new.organization_id IS NOT NULL THEN
      INSERT INTO public.user_roles (user_id, organization_id, role)
      VALUES (new.id, new.organization_id, mapped)
      ON CONFLICT (user_id, organization_id)
      DO UPDATE SET role = excluded.role;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_user_roles_from_app_users ON public.app_users;

CREATE TRIGGER trg_sync_user_roles_from_app_users
AFTER INSERT OR UPDATE OF role, organization_id ON public.app_users
FOR EACH ROW
EXECUTE FUNCTION public.sync_user_roles_from_app_users();

-- 4) Backfill: alinhar user_roles a app_users onde o slug for app_role conhecido
INSERT INTO public.user_roles (user_id, organization_id, role)
SELECT
  au.id,
  au.organization_id,
  au.role::app_role
FROM public.app_users au
WHERE au.organization_id IS NOT NULL
  AND trim(lower(au.role)) IN ('admin', 'vendedor', 'cliente')
ON CONFLICT (user_id, organization_id)
DO UPDATE SET role = excluded.role;
