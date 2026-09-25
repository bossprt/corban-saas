// Team administration: pure helpers (no I/O) shared by the server actions, the page and the unit tests.
// The database is the authority (RPCs in migration 20260925_team_access_lifecycle_v1); this only turns its governed errors into operator language.

export const ROLE_LABEL:Record<string,string>={admin:'Administrador',manager:'Gerente',supervisor:'Supervisor',agent:'Vendedor'}
export const STATUS_LABEL:Record<string,string>={active:'Ativo',inactive:'Desativado',revoked:'Removido'}
export const INVITE_STATUS_LABEL:Record<string,string>={pending:'Pendente',accepted:'Aceito',revoked:'Cancelado',expired:'Expirado'}

export const TEAM_ERROR_MESSAGES={
 not_authorized:'Seu perfil não pode fazer esta alteração.',
 role_change_not_permitted:'Seu perfil não pode atribuir ou alterar este perfil de acesso.',
 cannot_change_own_membership:'Você não pode alterar o seu próprio acesso.',
 membership_not_found:'Este membro não foi encontrado nesta organização.',
 invitation_not_found:'Este convite não foi encontrado.',
 invitation_already_pending:'Já existe um convite pendente para este e-mail.',
 invitation_already_resolved:'Este convite já foi aceito, cancelado ou expirou.',
 invitation_rate_limited:'Limite de convites por hora atingido. Tente novamente mais tarde.',
 invalid_email:'Informe um e-mail válido.',
 invalid_role:'Perfil de acesso inválido.',
 invalid_status:'Situação inválida.',
 no_change:'Nada mudou: o membro já está nesta situação.',
 invalid_input:'Dados inválidos.',
 organization_role_not_found:'Este papel não existe ou está desativado.',
 role_in_use:'Este papel ainda está atribuído a membros ativos. Mova-os antes de desativar.',
 invalid_role_name:'Informe um nome de papel com 2 a 60 caracteres.',
 invalid_role_key:'Código do papel inválido.',
 invalid_role_scope:'Escolha o alcance dos dados deste papel.',
 invalid_role_tier:'Nível de acesso inválido para este papel.',
 unknown_permission:'Uma das permissões não existe.',
 admin_role_is_fixed:'O papel Administrador não pode ser alterado.',
 branch_not_found:'Filial não encontrada ou inativa.',
 team_leader_not_found:'O líder escolhido não é um membro ativo (e ninguém lidera a si mesmo).',
 system_role_tier_immutable:'O nível de acesso de um papel padrão não pode mudar.',
 unexpected:'Não foi possível concluir. Nada foi alterado; tente novamente.'
} as const
export type TeamErrorCode=keyof typeof TEAM_ERROR_MESSAGES
export const isTeamErrorCode=(v:unknown):v is TeamErrorCode=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(TEAM_ERROR_MESSAGES,v)

export const TEAM_OK_MESSAGES={
 invited:'Convite criado e e-mail enviado.',
 invited_existing:'Convite criado. Este e-mail já tem conta: a pessoa vê o acesso ao entrar.',
 invited_no_email:'Convite criado, mas o e-mail não pôde ser enviado agora. Use Reenviar.',
 resent:'E-mail reenviado.',
 revoked:'Convite cancelado.',
 role_changed:'Perfil atualizado.',
 status_changed:'Situação do acesso atualizada.',
 role_saved:'Papel salvo.',
 hierarchy_changed:'Filial, equipe e alcance atualizados.'
} as const
export type TeamOkCode=keyof typeof TEAM_OK_MESSAGES
export const isTeamOkCode=(v:unknown):v is TeamOkCode=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(TEAM_OK_MESSAGES,v)

// PostgREST returns the RAISE text in `message`; permission errors (SQLSTATE 42501) mean the caller may not do it at all.
export function classifyTeamError(err:{message?:string;code?:string}|null|undefined):TeamErrorCode{
 const m=String(err?.message??'')
 if(err?.code==='42501'||/permission denied|row-level security/i.test(m))return 'not_authorized'
 // Longest match wins, so invalid_role_name is not read as invalid_role.
 const hit=(Object.keys(TEAM_ERROR_MESSAGES) as TeamErrorCode[])
  .filter(code=>code!=='unexpected'&&code!=='invalid_input'&&m.includes(code))
  .sort((a,b)=>b.length-a.length)[0]
 return hit??'unexpected'
}

const EMAIL=/^[^@\s]+@[^@\s]+$/
export function normalizeEmail(raw:unknown):string|null{
 const e=String(raw??'').trim().toLowerCase()
 return e.length>=3&&e.length<=254&&EMAIL.test(e)?e:null
}

export const AUDIT_LABEL:Record<string,string>={
 invite_created:'Convite criado',invite_revoked:'Convite cancelado',invite_accepted:'Convite aceito',
 member_role_changed:'Perfil alterado',member_deactivated:'Acesso desativado',member_reactivated:'Acesso reativado',
 role_created:'Papel criado',role_updated:'Papel alterado',member_access_role_changed:'Papel do membro alterado',member_hierarchy_changed:'Filial, equipe ou alcance alterados'
}

const UUID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const isUuid=(v:unknown):v is string=>typeof v==='string'&&UUID_RE.test(v)

// Supabase Auth reports an already registered address as email_exists (422). That is not a failure for us:
// the invitation row exists and the person accepts it after logging in.
export function isExistingUserError(err:{message?:string;code?:string;status?:number}|null|undefined):boolean{
 return !!err&&(err.code==='email_exists'||err.code==='user_already_exists'||/already (been )?registered|already exists/i.test(String(err.message??'')))
}
