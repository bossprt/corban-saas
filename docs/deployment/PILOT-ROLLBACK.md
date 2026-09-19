# Rollback e recuperação do piloto (sem instruções destrutivas)

Regra geral: o sistema não apaga dados de negócio e o histórico é imutável. "Voltar" significa **parar de usar / desativar / corrigir com um novo registro**, nunca apagar.

## Deploy falhou ou ficou instável
1. Na Vercel, promova o deployment anterior que estava saudável ("Promote to Production" / "Instant Rollback"). O banco não muda com o deploy.
2. Confirme `<APP_ORIGIN>/api/health`. Se `database` estiver `unavailable` o problema é o Supabase (status do projeto), não o deploy.
3. Registre o incidente (`docs/pilot/SMART-PILOT-INCIDENTS.md`).
4. Uma migration já aplicada NÃO se desfaz por rollback de deploy: o código antigo continua compatível (todas as migrations são aditivas). Não reverta banco sem o ChatGPT.

## Variável de ambiente errada
- Corrija na Vercel e faça redeploy. Nunca cole o valor em chat. Sintoma típico: "Configuração ausente" (URL/chave do Supabase) ou convite sem redirecionamento (`NEXT_PUBLIC_SITE_URL`).

## Convite falhou
- "Convite criado, mas o e-mail não pôde ser enviado": use **Reenviar** em Equipe. Se continuar: SMTP/limite de e-mails (`SUPABASE-AUTH-CONFIG.md` seção 2 e 3).
- Convite para e-mail digitado errado: **Cancelar** o convite e criar outro.
- Link inválido/expirado (7 dias): cancelar e reenviar.
- O convidado já tem conta em outra organização: ele vê o acesso ao entrar (ou em "Trocar organização"); nenhum e-mail é enviado.
- Primeiro administrador da Smart não recebeu o convite: NÃO repita a criação da organização. Peça ao agente/ChatGPT para reenviar o convite ao usuário já criado.

## Catálogo cadastrado errado
- Versão de tabela em **rascunho** com valor errado: crie outra versão (a numeração é automática) e publique a correta; a errada fica como rascunho sem uso.
- Versão **publicada** errada: ela é imutável. Crie uma nova versão correta e publique: a anterior passa a "Substituída" automaticamente e deixa de ser usada em novas simulações. Simulações/propostas já feitas mantêm o que foi calculado (registro histórico).
- Checklist errado: mesmo princípio (novo checklist publicado substitui o anterior; propostas já preparadas mantêm o próprio snapshot).
- Rota/tabela criada por engano: fica sem uso; não há exclusão.
- Etapas da operação duplicadas ou erradas: peça correção ao ChatGPT (sem exclusão pela interface).

## Operador com problema ou acesso indevido
1. Equipe → **Desativar acesso** (efeito imediato; próxima ação do usuário é recusada pelo banco). O histórico permanece.
2. Reativar quando resolvido.
3. Suspeita de senha comprometida: desativar o acesso e pedir "Esqueci minha senha" ao usuário depois de reativar.

## Organização criada em duplicidade ou com dados errados
- Não apague. Desative os acessos da organização errada (Equipe) e avise o ChatGPT: será tratada por migration revisada.

## Parar tudo
- Remover a variável `SUPABASE_SERVICE_ROLE_KEY` NÃO é seguro (quebra convites/equipe). O mecanismo seguro é desativar os acessos dos usuários em Equipe e pausar o projeto na Vercel.
