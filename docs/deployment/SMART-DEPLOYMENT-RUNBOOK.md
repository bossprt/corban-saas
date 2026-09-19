# Runbook de implantação - Smart Promotora (ações do Owner)

O agente NÃO executou nenhum passo abaixo. Ordem obrigatória. Marque cada item.

## Estado de partida (verificado)
- Banco (Supabase `nhjfrcttzxnphhizlnmc`): todas as migrations até `revoked_actor_dispatch_v1` estão LIVE. Pendentes (revisão do ChatGPT): `20260929_catalog_publish_v1` (publicar tabela/checklist sem SQL).
- Organização Smart Promotora: **não existe**. Catálogo de referência global (bancos, produtos, documentos): **vazio**.
- Repositório: build e testes verdes; `npm run preflight` valida o ambiente.

## 1. Escolher domínio / origem
- [ ] Definir `<APP_ORIGIN>` (https, sem barra final).

## 2. Projeto na Vercel
- [ ] Criar o projeto a partir do repositório `bossprt/corban-saas`, branch de produção escolhida pelo Owner (NÃO `main` direto sem revisão; hoje o trabalho está em `architecture/corban-os-master-v2`).
- Framework: Next.js (detectado). Build command: usar o do `package.json` (`next build --webpack`). Não há `vercel.json` e não é necessário. Node 20 ou 22.
- Observações de compatibilidade (auditadas):
  - Rotas usam runtime Node (padrão). `proxy.ts` é o middleware do Next 16.
  - Upload de documento passa por server action: limite **4 MB** (a Vercel recusa corpos > 4,5 MB; `serverActions.bodySizeLimit` = 5 MB). Arquivos maiores exigem upload direto ao Storage (P1).
  - Rota do worker `POST /api/integrations/dispatch`: `maxDuration = 60` (aceito no plano Hobby; sem agendador nada a chama).
  - `crypto`/`Buffer` só em código de servidor; nenhum código edge incompatível.

## 3. Variáveis de ambiente (Vercel → Settings → Environment Variables, ambiente Production)
- [ ] `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (Supabase → Project Settings → API).
- [ ] `SUPABASE_SERVICE_ROLE_KEY` (mesma tela; marque como sensível; nunca em `NEXT_PUBLIC_`).
- [ ] `NEXT_PUBLIC_SITE_URL=<APP_ORIGIN>`.
- NÃO defina agora: `INTEGRATION_WORKER_SECRET`, `CORBAN_ALLOW_LOCAL_PROVIDERS`.
- Detalhes: `docs/deployment/ENVIRONMENT-VARIABLES.md`. Verificação local antes: `npm run preflight -- --production` com as mesmas variáveis num `.env.production.local` (não commitar).

## 4. Deploy
- [ ] Disparar o deploy. Abrir `<APP_ORIGIN>/api/health`: deve responder `{"status":"ok","app":"ok","database":"ok"}` (503 `degraded` se o banco não responder). Nenhuma configuração aparece na resposta.
- [ ] Abrir `<APP_ORIGIN>/login`: a tela de login aparece.

## 5. Supabase Auth e SMTP
- [ ] Seguir `docs/deployment/SUPABASE-AUTH-CONFIG.md` inteiro (Site URL, Redirect URL, SMTP, senha, cadastro público desligado).

## 6. Aplicar a migration do catálogo (via ChatGPT)
- [ ] `20260929_catalog_publish_v1` revisada e aplicada; harness `catalog-publish-rollback.sql` em modo LIVE (só o bloco DO).
- Até lá, criar rotas/tabelas/versões em rascunho funciona, mas "Publicar" responde "recurso ainda não disponível".

## 7. Catálogo de referência (uma vez, administrador de plataforma)
Só o administrador de plataforma pode. Entre no sistema com a conta dele (se ela ainda não tiver organização, a tela "Acesso ainda não liberado" serve: o console funciona em qualquer página do endereço) e abra o console do navegador (F12):
`fetch('/api/admin/reference-catalog',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(<conteudo>)}).then(r=>r.json()).then(console.log)`
- Conteúdo: copie `docs/deployment/reference-catalog.template.json`, troque TODOS os `<...>` pelos códigos e nomes reais (bancos, provedores, convênios, produtos, modalidades e tipos de documento que a Smart trabalha). O sistema não inventa nenhum.
- Resposta esperada: status 201 com as contagens. É idempotente (repetir atualiza nomes por código; nada é apagado). Conferir: `fetch('/api/admin/reference-catalog').then(r=>r.json()).then(console.log)`.

## 8. Criar a organização Smart Promotora e o primeiro administrador (uma vez)
No console, como administrador de plataforma:
`fetch('/api/admin/organizations',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'<email-do-admin-smart>',organizationName:'Smart Promotora',organizationDocument:'<CNPJ>',fullName:'<nome>'})}).then(r=>r.json()).then(console.log)`
- CNPJ com dígitos verificadores válidos (pontuação opcional; é guardado só com números; não pode repetir).
- Respostas: `201 {organizationId}`; `409 organization_document_exists` (CNPJ já cadastrado); `409 similar_organization_exists` (nome parecido já existe: confira; se for mesmo outra empresa, repita com `"confirmSimilarName":true`); `400 invalid_cnpj`; `400 invite_failed` (o e-mail já tem conta ou o envio falhou).
- NÃO repita o comando após um 201.
- O convite chega ao e-mail do administrador (depende do passo 5).

## 9. Primeiro login e configuração pelo navegador (administrador da Smart)
- [ ] Criar a senha pelo convite e entrar. Menu **Configuração**: mostra o que falta.
- [ ] **Catálogo**: (1) "Criar etapas padrão"; (2) criar a rota comercial; (3) criar a tabela e uma versão com taxa/coeficiente REAIS e prazos; publicar; (4) criar o checklist de documentos, adicionar os tipos exigidos, publicar.
- [ ] **Equipe**: convidar supervisor e operador.

## 10. Teste de aceitação
- [ ] `docs/pilot/SMART-HUMAN-ACCEPTANCE-TEST.md` inteiro, com dados fictícios, ANTES do primeiro operador real.

## Não ativar no piloto inicial
Worker/scheduler, integrações reais, Bevicred, 2Tech.

## Limites conhecidos
- Documentos até 4 MB. - Sem teste automatizado de navegador. - Erros aparecem com referência (digest) para o suporte.
