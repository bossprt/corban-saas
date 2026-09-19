// Operator feedback for server actions. In production Next.js hides the message of an Error thrown by a server action, so the operator would only
// see a generic failure. Actions therefore REDIRECT back with a short code (?f=erro:<code> | ?f=ok:<code>) and the shell shows the text below.
// Only codes from this whitelist are ever rendered: arbitrary text in the URL can never reach the screen.
export const FEEDBACK = {
  // success
  'ok:lead_registrado': 'Lead registrado.',
  'ok:lead_atualizado': 'Lead atualizado.',
  'ok:lead_convertido': 'Lead convertido em cliente. Você já pode fazer uma simulação.',
  'ok:cliente_cadastrado': 'Cliente cadastrado.',
  'ok:simulacao_registrada': 'Simulação registrada. Agora você pode criar a proposta.',
  'ok:proposta_criada': 'Proposta criada.',
  'ok:doc_enviado': 'Documento enviado.',
  'ok:checklist_preparado': 'Checklist de documentos preparado.',
  'ok:doc_vinculado': 'Documento vinculado à proposta.',
  'ok:requisito_validado': 'Documento validado.',
  'ok:enviado_digitacao': 'Proposta enviada para a operação.',
  // errors
  'erro:nome_invalido': 'Informe um nome válido.',
  'erro:canal_invalido': 'Canal inválido.',
  'erro:cpf_invalido': 'CPF inválido. Confira os 11 dígitos.',
  'erro:cpf_duplicado': 'Já existe um cliente com este CPF nesta organização.',
  'erro:email_invalido': 'E-mail inválido.',
  'erro:requisicao_invalida': 'Não foi possível entender o pedido. Atualize a página e tente de novo.',
  'erro:motivo_obrigatorio': 'Informe o motivo da perda.',
  'erro:sem_permissao': 'Seu perfil não pode fazer isto.',
  'erro:indisponivel': 'Este recurso ainda não está disponível neste ambiente.',
  'erro:inesperado': 'Não foi possível concluir. Nada foi alterado; tente de novo. Se repetir, avise o supervisor.',
  'erro:proposta_duplicada': 'Esta simulação já virou proposta.',
  'erro:simulacao_indisponivel': 'Esta simulação não está mais disponível para proposta.',
  'erro:doc_invalido': 'Escolha o cliente, o tipo de documento e o arquivo.',
  'erro:doc_vazio': 'O arquivo está vazio.',
  'erro:doc_grande': 'O arquivo passa de 15 MB.',
  'erro:doc_formato': 'Formato não permitido. Envie PDF, JPG, PNG ou WebP.',
  'erro:doc_duplicado': 'Este mesmo arquivo já foi enviado para este cliente.',
  'erro:doc_indisponivel': 'Cliente ou tipo de documento indisponível.',
  'erro:doc_armazenamento': 'Não foi possível guardar o arquivo. Tente de novo.',
  'erro:doc_registro': 'O arquivo foi guardado, mas o registro falhou. Não envie de novo: avise o supervisor.',
  'erro:doc_incompativel': 'Este documento não corresponde ao tipo exigido.',
  'erro:checklist': 'Não foi possível preparar o checklist. Confirme que existe um checklist publicado para este produto.',
  'erro:envio_digitacao': 'A proposta não pôde ser enviada. Confirme que os documentos obrigatórios estão anexados e validados.',
  'erro:requisito': 'Não foi possível atualizar o documento.',
  'erro:sim_customer_not_found_or_forbidden': 'Cliente não encontrado nesta organização.',
  'erro:sim_published_table_version_not_available': 'A tabela escolhida não está publicada para esta organização.',
  'erro:sim_term_below_table_minimum': 'Prazo abaixo do mínimo da tabela.',
  'erro:sim_term_above_table_maximum': 'Prazo acima do máximo da tabela.',
  'erro:sim_invalid_amount': 'Informe um valor solicitado válido.',
  'erro:sim_invalid_term': 'Informe um prazo válido.',
} as const
export type FeedbackCode = keyof typeof FEEDBACK
export const isFeedbackCode = (v: unknown): v is FeedbackCode => typeof v === 'string' && Object.prototype.hasOwnProperty.call(FEEDBACK, v)
export const feedbackTone = (c: FeedbackCode) => (c.startsWith('ok:') ? 'ok' : 'erro')

export const feedbackUrl = (path: string, code: FeedbackCode) => `${path}?f=${encodeURIComponent(code)}`

// Maps a database/PostgREST error to a code WITHOUT ever exposing its text.
export function classifyDbFeedback(err: { message?: string; code?: string } | null | undefined): FeedbackCode {
  const m = String(err?.message ?? '')
  if (err?.code === '23505') return 'erro:cpf_duplicado'
  if (err?.code === 'PGRST202' || err?.code === '42P01' || err?.code === 'PGRST205') return 'erro:indisponivel'
  if (err?.code === '42501' || /forbidden|not_authorized|permission denied/i.test(m)) return 'erro:sem_permissao'
  return 'erro:inesperado'
}
