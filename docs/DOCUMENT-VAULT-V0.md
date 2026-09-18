# DOCUMENT VAULT / CHECKLIST V0

**Status:** preparado no Git; não aplicado.

O Customer possui documentos reutilizáveis e versionados. A Proposal não duplica arquivo físico: ela cria requisitos e links para a evidência exata utilizada.

Fluxo: DocumentType → CustomerDocument → ChecklistTemplate/Items → ProposalDocumentRequirement → ProposalDocumentLink.

Cada arquivo preserva bucket/path, nome original, MIME, tamanho e SHA-256. O hash ajuda a evitar duplicação acidental e mantém rastreabilidade. A segurança do objeto no Supabase Storage será tratada separadamente; registrar path no banco não concede acesso ao arquivo.

Checklist é versionado por rota comercial do tenant. Ao criar a proposta, os requisitos devem virar snapshots; mudanças posteriores no template não reescrevem a exigência histórica.

Exceção documental só pode ficar `waived` com motivo, aprovador e timestamp. Isso prepara o Human Gate para envio à digitação.

Todas as referências críticas tenant-scoped usam FKs compostas. Usuário autenticado não recebe DELETE. Template publicado só pode ser alterado por fluxo privilegiado/versionamento; policy normal de UPDATE aceita apenas draft.
