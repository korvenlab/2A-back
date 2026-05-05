-- Enforce one role per user/org and fix signup role assignment.

-- 1) Keep a single role per user per organization.
WITH ranked_roles AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY user_id, organization_id
      ORDER BY created_at ASC, id ASC
    ) AS rn
  FROM public.user_roles
)
DELETE FROM public.user_roles ur
USING ranked_roles rr
WHERE ur.id = rr.id
  AND rr.rn > 1;

ALTER TABLE public.user_roles
  DROP CONSTRAINT IF EXISTS user_roles_user_id_organization_id_role_key;

ALTER TABLE public.user_roles
  DROP CONSTRAINT IF EXISTS user_roles_user_id_organization_id_key;

ALTER TABLE public.user_roles
  ADD CONSTRAINT user_roles_user_id_organization_id_key UNIQUE (user_id, organization_id);

-- 2) Signup trigger: assign exactly one role (no implicit admin escalation).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  new_org_id UUID;
  org_name TEXT;
  org_slug TEXT;
  user_role app_role;
BEGIN
  org_name := COALESCE(
    NEW.raw_user_meta_data->>'organization_name',
    NEW.raw_user_meta_data->>'full_name',
    split_part(NEW.email, '@', 1)
  ) || '''s Workspace';

  org_slug := lower(
    regexp_replace(
      coalesce(NEW.raw_user_meta_data->>'organization_name', split_part(NEW.email, '@', 1)),
      '[^a-zA-Z0-9]+',
      '-',
      'g'
    )
  ) || '-' || substr(NEW.id::text, 1, 8);

  user_role := COALESCE((NEW.raw_user_meta_data->>'role')::app_role, 'admin'::app_role);

  INSERT INTO public.organizations (name, slug)
  VALUES (org_name, org_slug)
  RETURNING id INTO new_org_id;

  INSERT INTO public.profiles (id, organization_id, full_name, email, avatar_url)
  VALUES (
    NEW.id,
    new_org_id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name'),
    NEW.email,
    NEW.raw_user_meta_data->>'avatar_url'
  );

  INSERT INTO public.user_roles (user_id, organization_id, role)
  VALUES (NEW.id, new_org_id, user_role);

  RETURN NEW;
END;
$$;

-- 3) Tighten order_items permissions by role.
DROP POLICY IF EXISTS "Manage items of own/admin orders" ON public.order_items;

DROP POLICY IF EXISTS "Admin manages items" ON public.order_items;
CREATE POLICY "Admin manages items"
ON public.order_items FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND o.organization_id = current_user_org()
      AND has_role(auth.uid(), 'admin'::app_role)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND o.organization_id = current_user_org()
      AND has_role(auth.uid(), 'admin'::app_role)
  )
);

DROP POLICY IF EXISTS "Vendedor manages own order items" ON public.order_items;
CREATE POLICY "Vendedor manages own order items"
ON public.order_items FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND o.organization_id = current_user_org()
      AND o.seller_id = auth.uid()
      AND has_role(auth.uid(), 'vendedor'::app_role)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND o.organization_id = current_user_org()
      AND o.seller_id = auth.uid()
      AND has_role(auth.uid(), 'vendedor'::app_role)
  )
);
