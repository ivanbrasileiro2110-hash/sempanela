# SemPanela

O app que organiza a sua pelada.

- `index.html`: o app (PWA), gerado a partir do protótipo
- `config.js`: endereço e chave pública do Supabase
- `vendor/supabase.js`: biblioteca do Supabase (v2.117.3)
- `supabase/schema.sql`: banco de dados (tabelas, regras de segurança, funções). Pode rodar de novo no SQL Editor sem quebrar.
- `download/`: página para instalar o app (`/download`)
- `sw.js` e `manifest.webmanifest`: instalação e funcionamento offline
- `vercel.json`: rotas (`/convite/SP0001`) e cabeçalhos

Cada envio para a branch `main` é publicado automaticamente pela Vercel.
