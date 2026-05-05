
-- Enum de roles
CREATE TYPE public.app_role AS ENUM ('admin', 'vendedor', 'cliente');

-- Organizations (Representações)
CREATE TABLE public.organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Profiles
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id UUID REFERENCES public.organizations(id) ON DELETE SET NULL,
  full_name TEXT,
  email TEXT,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- User roles
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,
  role app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, organization_id, role)
);

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Security definer: has_role
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role = _role
  )
$$;

-- Get current user's organization
CREATE OR REPLACE FUNCTION public.current_user_org()
RETURNS UUID
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT organization_id FROM public.profiles WHERE id = auth.uid()
$$;

-- Get primary role for current user
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS app_role
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT role FROM public.user_roles WHERE user_id = auth.uid()
  ORDER BY CASE role WHEN 'admin' THEN 1 WHEN 'vendedor' THEN 2 WHEN 'cliente' THEN 3 END
  LIMIT 1
$$;

-- RLS: organizations
CREATE POLICY "View own organization" ON public.organizations
  FOR SELECT TO authenticated USING (id = public.current_user_org());
CREATE POLICY "Admin can update own organization" ON public.organizations
  FOR UPDATE TO authenticated USING (id = public.current_user_org() AND public.has_role(auth.uid(), 'admin'));

-- RLS: profiles
CREATE POLICY "View own profile" ON public.profiles
  FOR SELECT TO authenticated USING (id = auth.uid() OR organization_id = public.current_user_org());
CREATE POLICY "Update own profile" ON public.profiles
  FOR UPDATE TO authenticated USING (id = auth.uid());
CREATE POLICY "Insert own profile" ON public.profiles
  FOR INSERT TO authenticated WITH CHECK (id = auth.uid());

-- RLS: user_roles
CREATE POLICY "View roles in own org" ON public.user_roles
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR organization_id = public.current_user_org());
CREATE POLICY "Admin manages org roles" ON public.user_roles
  FOR ALL TO authenticated
  USING (organization_id = public.current_user_org() AND public.has_role(auth.uid(), 'admin'))
  WITH CHECK (organization_id = public.current_user_org() AND public.has_role(auth.uid(), 'admin'));

-- Trigger: on signup -> create org + profile + admin role
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
  org_name := COALESCE(NEW.raw_user_meta_data->>'organization_name', NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)) || '''s Workspace';
  org_slug := lower(regexp_replace(coalesce(NEW.raw_user_meta_data->>'organization_name', split_part(NEW.email, '@', 1)), '[^a-zA-Z0-9]+', '-', 'g')) || '-' || substr(NEW.id::text, 1, 8);
  user_role := COALESCE((NEW.raw_user_meta_data->>'role')::app_role, 'admin'::app_role);

  INSERT INTO public.organizations (name, slug) VALUES (org_name, org_slug) RETURNING id INTO new_org_id;

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

  -- If self-signup as admin, also add the admin role on the org
  IF user_role <> 'admin' THEN
    INSERT INTO public.user_roles (user_id, organization_id, role)
    VALUES (NEW.id, new_org_id, 'admin');
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
