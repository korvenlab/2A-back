-- Fix seller invite signup flow and product visibility by role.

-- 1) Replace signup trigger function to support invited sellers.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  new_org_id UUID;
  org_name TEXT;
  org_slug TEXT;
  user_role app_role;
  invite_token TEXT;
  invited_org_id UUID;
BEGIN
  invite_token := NULLIF(NEW.raw_user_meta_data->>'invite_token', '');

  IF invite_token IS NOT NULL THEN
    SELECT si.organization_id
      INTO invited_org_id
    FROM public.seller_invitations si
    WHERE si.token = invite_token
      AND si.accepted_at IS NULL
      AND si.expires_at > now()
    LIMIT 1;
  END IF;

  IF invited_org_id IS NOT NULL THEN
    new_org_id := invited_org_id;
    user_role := 'vendedor'::app_role;
  ELSE
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
  END IF;

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

  IF invite_token IS NOT NULL AND invited_org_id IS NOT NULL THEN
    UPDATE public.seller_invitations
    SET accepted_at = now()
    WHERE token = invite_token
      AND accepted_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

-- 2) Ensure clients only see active products.
DROP POLICY IF EXISTS "View org products" ON public.products;
