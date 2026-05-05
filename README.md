# 2AVendas — Backend (API + Supabase)

Este diretório é pensado para virar **repositório Git próprio** e um **Web Service na Render**.

## O que existe aqui

- **`src/index.ts`** — API HTTP mínima (Hono): `/health` e `/`. Amplie com rotas que usem `supabaseAdmin`.
- **`src/supabase/admin-client.ts`** — cliente com **service role** (só servidor).
- **`supabase/`** — migrations e `config.toml` para **Supabase CLI** (`cd` nesta pasta ou neste repo após o split).

## Variáveis de ambiente (Render → Environment)

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `FRONTEND_ORIGIN` — URL do frontend na Vercel (CORS). Várias origens: separadas por vírgula.

## Deploy Render

1. Novo repositório só com o conteúdo de **`backend/`** (ver `REPOSITORIOS-GITHUB.md` na raiz do monorepo).
2. Na Render: **New Web Service** → conecte o repo.
3. **Root Directory**: `.` (raiz do repo backend).
4. **Build**: `npm install && npm run build` · **Start**: `npm start`
5. Opcional: use `render.yaml` como blueprint.

## Tipos do banco (`database.types.ts`)

Gerados/copiados a partir do schema Supabase. Se atualizar o schema no Supabase, regenere os tipos (CLI ou Dashboard) e substitua `src/database.types.ts`, ou copie de `frontend/src/integrations/supabase/types.ts` enquanto mantiver os dois projetos alinhados.
