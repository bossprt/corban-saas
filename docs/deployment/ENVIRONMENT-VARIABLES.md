# Variáveis de ambiente do Corban OS

Inventário real: gerado varrendo `process.env` em `src/`, `proxy.ts`, `next.config.ts` e `scripts/` (2026-09-25). Nenhum valor real está neste repositório. `.env.local` está no `.gitignore`.
Verificação local sem imprimir valores: `npm run preflight` (ou `npm run preflight -- --production`).

## Obrigatórias (o app não funciona sem elas)
| Variável | Onde é usada | Servidor-only? | Pode ser pública? | Exemplo (fictício) | Se faltar |
|---|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `utils/supabase/{server,middleware}.ts`, `lib/supabaseClient.ts`, `lib/supabaseAdmin.ts`, `/api/health` | não | sim (vai para o navegador) | `https://abcdefgh.supabase.co` | toda requisição falha com "Configuração ausente" (falha fechada); login impossível |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | mesmos arquivos + `/api/health` | não | sim (chave publicável; a segurança vem de RLS) | `eyJ...` / `sb_publishable_...` | idem |
| `SUPABASE_SERVICE_ROLE_KEY` | `lib/supabaseAdmin.ts` (importa `server-only`): convites, aceite de convite, e-mails de membros, bootstrap de organização, catálogo de referência, worker | **SIM** | **NUNCA** | `eyJ...` (segredo) | convite, equipe, criação da organização e worker falham com erro claro; o operador que já tem acesso continua trabalhando |

## Obrigatória em produção (recomendada em desenvolvimento)
| Variável | Onde | Servidor-only? | Pública? | Exemplo | Se faltar |
|---|---|---|---|---|---|
| `NEXT_PUBLIC_SITE_URL` | `lib/site-origin.ts` (links de convite e de recuperação de senha) | não (é só uma origem) | sim | `https://app.suaempresa.com.br` (sem barra, sem caminho) | o código usa a origem da própria requisição apenas se for do mesmo host; senão o e-mail sai sem redirecionamento e o convidado cai fora do fluxo de criar senha. `npm run preflight` marca BLOCKED em produção |

## Fornecidas pela plataforma
| Variável | Origem |
|---|---|
| `NODE_ENV` | definida pelo Next.js (`production` no `next build`/Vercel); usada em `organizacao/actions.ts` (cookie `secure`) e no guard do provedor fake |

## Regras
- Qualquer variável com `NEXT_PUBLIC_` vai para o navegador. Nunca use esse prefixo para segredos (teste automático e o preflight bloqueiam `NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY`).
- `SUPABASE_SERVICE_ROLE_KEY` só é importada por módulos `server-only`; um teste de arquitetura falha se um componente de cliente a alcançar.
- Nunca cole valores de segredo em chat, issue, log ou print. Para diagnóstico use apenas "definida/ausente".
