# 2AVendas — Backend (API + Supabase)

Este diretório é pensado para virar **repositório Git próprio** e um **Web Service na Render**.

## O que existe aqui

- **`src/index.ts`** — API HTTP (Hono): `/health`, `/`, **`GET /metrics`** e **`GET /dashboard`**.
- **`src/metrics-route.ts`** — KPIs compactos (`dashboard_metrics_summary`).
- **`src/dashboard-route.ts`** — payload executivo completo (`dashboard_full_payload`): cards, séries diárias, eventos e metadados de UI (sidebar/topbar/gráficos).
- **`src/api-key-auth.ts`** — validação compartilhada da **`METRICS_API_KEY`**.
- **`src/supabase/admin-client.ts`** — cliente com **service role** (só servidor).
- **`supabase/`** — migrations e `config.toml` para **Supabase CLI** (`cd` nesta pasta ou neste repo após o split).

### GET `/dashboard` (principal)

Mesma autenticação que `/metrics` (**Bearer** ou **`X-API-Key`**).

**Query opcional:**

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `organization_id` | — | UUID da organização 2AVENDAS para filtrar pedidos e assinaturas. |
| `period_days` | `30` | Janela do KPI (e período anterior de igual tamanho para **variacao_pct**). |
| `chart_days` | `14` | Pontos nos gráficos de área (Wagoo) e barras (2AVENDAS). |

Exemplo: `GET /dashboard?period_days=30&chart_days=14&organization_id=<uuid>`

O JSON inclui:

- **`kpis`** — receita total (Wagoo diário + pedidos 2AVENDAS), assinaturas ativas Wagoo, volume de pedidos 2AVENDAS, uptime médio.
- **`wagoo`** — `assinaturas_ativas` e **`receita_por_dia`** (área; dados em `dashboard_daily_app_metrics`, app `wagoo`).
- **`dois_avendas`** — `volume_pedidos_periodo` e **`volume_por_dia`** (contagem de `orders` não cancelados).
- **`eventos_recentes`** — até 50 linhas de `dashboard_app_logs` (`timestamp`, `app`, `mensagem`, `status`: `online` \| `degraded` \| `offline`).
- **`ui`** — rótulos sugeridos para sidebar, topbar e tipo/título dos gráficos + mapa de badges para o frontend.

**Ingestão:** inserir linhas em `dashboard_daily_app_metrics` (receita Wagoo), `dashboard_system_health` (uptime diário) e `dashboard_app_logs` (eventos). Assinaturas Wagoo usam `assinaturas.produto = 'wagoo'` (default).

### GET `/metrics`

1. Aplique as migrations (criam `assinaturas`, a view `vendas` sobre `orders` e a função SQL `dashboard_metrics_summary`).
2. Defina `METRICS_API_KEY` no servidor (valor secreto, alta entropia).
3. Chame com **`Authorization: Bearer <METRICS_API_KEY>`** ou **`X-API-Key: <METRICS_API_KEY>`**.

Resposta JSON exemplo:

```json
{
  "ok": true,
  "gerado_em": "2026-05-06T21:00:00.000Z",
  "assinaturas": {
    "quantidade": 10,
    "quantidade_pagas": 7,
    "quantidade_nao_pagas": 3,
    "soma_valor_mensal": 990,
    "soma_valor_mensal_pago": 693,
    "soma_valor_mensal_pendente": 297
  },
  "vendas": { "quantidade": 128, "soma_valor_total": 45231.5 }
}
```

A tabela **`assinaturas`** deve ser preenchida pelo fluxo de cobrança/admin. Campos **`pago`** (boolean) e opcionalmente **`pago_em`** indicam se foi quitado; o **`GET /metrics`** separa contagens e somas pagas vs pendentes. **`vendas`** continua sendo uma view sobre **`orders`**.

## Variáveis de ambiente (Render → Environment)

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `METRICS_API_KEY` — obrigatória para **`GET /metrics`** e **`GET /dashboard`** responderem 200.
- `FRONTEND_ORIGIN` — URL do frontend na Vercel (CORS). Várias origens: separadas por vírgula.

## Deploy Render

1. Novo repositório só com o conteúdo de **`backend/`** (ver `REPOSITORIOS-GITHUB.md` na raiz do monorepo).
2. Na Render: **New Web Service** → conecte o repo.
3. **Root Directory**: `.` (raiz do repo backend).
4. **Build**: `npm install && npm run build` · **Start**: `npm start`
5. Opcional: use `render.yaml` como blueprint.

## Tipos do banco (`database.types.ts`)

Gerados/copiados a partir do schema Supabase. Se atualizar o schema no Supabase, regenere os tipos (CLI ou Dashboard) e substitua `src/database.types.ts`, ou copie de `frontend/src/integrations/supabase/types.ts` enquanto mantiver os dois projetos alinhados.
