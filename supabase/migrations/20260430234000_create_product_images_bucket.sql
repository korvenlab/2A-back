-- Product images bucket and RLS policies.

INSERT INTO storage.buckets (id, name, public)
VALUES ('product-images', 'product-images', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "Public can view product images" ON storage.objects;
CREATE POLICY "Public can view product images"
ON storage.objects FOR SELECT
USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Admin and seller can upload product images" ON storage.objects;
CREATE POLICY "Admin and seller can upload product images"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'product-images'
  AND (public.has_role(auth.uid(), 'admin'::public.app_role) OR public.has_role(auth.uid(), 'vendedor'::public.app_role))
  AND split_part(name, '/', 1) = 'org'
  AND split_part(name, '/', 2) = public.current_user_org()::text
);

DROP POLICY IF EXISTS "Admin and seller can update product images" ON storage.objects;
CREATE POLICY "Admin and seller can update product images"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'product-images'
  AND (public.has_role(auth.uid(), 'admin'::public.app_role) OR public.has_role(auth.uid(), 'vendedor'::public.app_role))
  AND split_part(name, '/', 1) = 'org'
  AND split_part(name, '/', 2) = public.current_user_org()::text
)
WITH CHECK (
  bucket_id = 'product-images'
  AND (public.has_role(auth.uid(), 'admin'::public.app_role) OR public.has_role(auth.uid(), 'vendedor'::public.app_role))
  AND split_part(name, '/', 1) = 'org'
  AND split_part(name, '/', 2) = public.current_user_org()::text
);

DROP POLICY IF EXISTS "Admin and seller can delete product images" ON storage.objects;
CREATE POLICY "Admin and seller can delete product images"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'product-images'
  AND (public.has_role(auth.uid(), 'admin'::public.app_role) OR public.has_role(auth.uid(), 'vendedor'::public.app_role))
  AND split_part(name, '/', 1) = 'org'
  AND split_part(name, '/', 2) = public.current_user_org()::text
);
