
-- ============== PRODUCTS ==============
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  sku TEXT,
  description TEXT,
  price NUMERIC(12,2) NOT NULL DEFAULT 0,
  stock INTEGER NOT NULL DEFAULT 0,
  image_url TEXT,
  category TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_org ON public.products(organization_id);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View org products" ON public.products FOR SELECT TO authenticated
  USING (organization_id = current_user_org());
CREATE POLICY "Admin manages products" ON public.products FOR ALL TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'))
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));
CREATE POLICY "Vendedor manages products" ON public.products FOR ALL TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor'))
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor'));

-- ============== CUSTOMERS ==============
CREATE TABLE public.customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  assigned_seller_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  document TEXT,
  address TEXT,
  city TEXT,
  state TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_customers_org ON public.customers(organization_id);
CREATE INDEX idx_customers_seller ON public.customers(assigned_seller_id);
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin views all customers" ON public.customers FOR SELECT TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));
CREATE POLICY "Vendedor views own customers" ON public.customers FOR SELECT TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND assigned_seller_id = auth.uid());
CREATE POLICY "Admin manages customers" ON public.customers FOR ALL TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'))
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));
CREATE POLICY "Vendedor manages own customers" ON public.customers FOR INSERT TO authenticated
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND assigned_seller_id = auth.uid());
CREATE POLICY "Vendedor updates own customers" ON public.customers FOR UPDATE TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND assigned_seller_id = auth.uid());

-- ============== ORDERS ==============
CREATE TYPE order_status AS ENUM ('rascunho', 'enviado', 'aprovado', 'faturado', 'cancelado');

CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  order_number INTEGER NOT NULL,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  seller_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  status order_status NOT NULL DEFAULT 'rascunho',
  total NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(organization_id, order_number)
);
CREATE INDEX idx_orders_org ON public.orders(organization_id);
CREATE INDEX idx_orders_seller ON public.orders(seller_id);
CREATE INDEX idx_orders_customer ON public.orders(customer_id);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin views all orders" ON public.orders FOR SELECT TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));
CREATE POLICY "Vendedor views own orders" ON public.orders FOR SELECT TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND seller_id = auth.uid());
CREATE POLICY "Admin manages orders" ON public.orders FOR ALL TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'))
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));
CREATE POLICY "Vendedor creates own orders" ON public.orders FOR INSERT TO authenticated
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND seller_id = auth.uid());
CREATE POLICY "Vendedor updates own orders" ON public.orders FOR UPDATE TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'vendedor') AND seller_id = auth.uid());

-- ============== ORDER ITEMS ==============
CREATE TABLE public.order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  unit_price NUMERIC(12,2) NOT NULL DEFAULT 0,
  subtotal NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_order_items_order ON public.order_items(order_id);
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View items of accessible orders" ON public.order_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));
CREATE POLICY "Manage items of own/admin orders" ON public.order_items FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id))
  WITH CHECK (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));

-- ============== SELLER INVITATIONS ==============
CREATE TABLE public.seller_invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  accepted_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_invites_org ON public.seller_invitations(organization_id);
ALTER TABLE public.seller_invitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin manages invites" ON public.seller_invitations FOR ALL TO authenticated
  USING (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'))
  WITH CHECK (organization_id = current_user_org() AND has_role(auth.uid(), 'admin'));

-- ============== ORDER NUMBER TRIGGER ==============
CREATE OR REPLACE FUNCTION public.set_order_number()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.order_number IS NULL OR NEW.order_number = 0 THEN
    SELECT COALESCE(MAX(order_number), 0) + 1 INTO NEW.order_number
    FROM public.orders WHERE organization_id = NEW.organization_id;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_set_order_number
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.set_order_number();

-- ============== UPDATED_AT TRIGGERS ==============
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE TRIGGER trg_products_updated BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============== AUTO-RECALC ORDER TOTAL ==============
CREATE OR REPLACE FUNCTION public.recalc_order_total()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE oid UUID;
BEGIN
  oid := COALESCE(NEW.order_id, OLD.order_id);
  UPDATE public.orders SET total = COALESCE((SELECT SUM(subtotal) FROM public.order_items WHERE order_id = oid), 0)
  WHERE id = oid;
  RETURN NULL;
END; $$;

CREATE TRIGGER trg_recalc_order_total
  AFTER INSERT OR UPDATE OR DELETE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.recalc_order_total();
