-- 1. Add user_id to customers (link auth.users -> customer record)
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS user_id UUID;
CREATE INDEX IF NOT EXISTS idx_customers_user_id ON public.customers(user_id);

-- 2. Products: clientes só veem ativos
DROP POLICY IF EXISTS "Cliente views active products" ON public.products;
CREATE POLICY "Cliente views active products"
ON public.products FOR SELECT
TO authenticated
USING (
  organization_id = current_user_org()
  AND has_role(auth.uid(), 'cliente'::app_role)
  AND active = true
);

-- 3. Customers: cliente vê o próprio cadastro
DROP POLICY IF EXISTS "Cliente views own customer record" ON public.customers;
CREATE POLICY "Cliente views own customer record"
ON public.customers FOR SELECT
TO authenticated
USING (
  organization_id = current_user_org()
  AND has_role(auth.uid(), 'cliente'::app_role)
  AND user_id = auth.uid()
);

-- 4. Orders: cliente vê os próprios
DROP POLICY IF EXISTS "Cliente views own orders" ON public.orders;
CREATE POLICY "Cliente views own orders"
ON public.orders FOR SELECT
TO authenticated
USING (
  organization_id = current_user_org()
  AND has_role(auth.uid(), 'cliente'::app_role)
  AND customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid())
);

-- 5. Orders: cliente cria pedido para si
DROP POLICY IF EXISTS "Cliente creates own orders" ON public.orders;
CREATE POLICY "Cliente creates own orders"
ON public.orders FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = current_user_org()
  AND has_role(auth.uid(), 'cliente'::app_role)
  AND customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid())
);

-- 6. Orders: cliente atualiza apenas rascunho próprio (ex.: enviar)
DROP POLICY IF EXISTS "Cliente updates own draft orders" ON public.orders;
CREATE POLICY "Cliente updates own draft orders"
ON public.orders FOR UPDATE
TO authenticated
USING (
  organization_id = current_user_org()
  AND has_role(auth.uid(), 'cliente'::app_role)
  AND customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid())
  AND status IN ('rascunho','enviado')
);

-- 7. Order items: as policies existentes já liberam quem enxerga o pedido — manter.
-- Para permitir cliente inserir/atualizar itens em rascunho próprio, adicionamos política dedicada:
DROP POLICY IF EXISTS "Cliente manages items of own draft orders" ON public.order_items;
CREATE POLICY "Cliente manages items of own draft orders"
ON public.order_items FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.customers c ON c.id = o.customer_id
    WHERE o.id = order_items.order_id
      AND c.user_id = auth.uid()
      AND o.status = 'rascunho'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.customers c ON c.id = o.customer_id
    WHERE o.id = order_items.order_id
      AND c.user_id = auth.uid()
      AND o.status = 'rascunho'
  )
);