// Team administration: pure helpers (no I/O) shared by the server actions, the page and the unit tests.
// The database is the authority (RPCs in migration 20260925_team_access_lifecycle_v1); this only turns its governed errors into operator language.

export const ROLE_LABEL:Record<string,string>={admin:'Administrador',manager:'Gerente',supervisor:'Supervisor',agent:'Operador'}
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
 status_changed:'Situação do acesso atualizada.'
} as const
export type TeamOkCode=keyof typeof TEAM_OK_MESSAGES
export const isTeamOkCode=(v:unknown):v is TeamOkCode=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(TEAM_OK_MESSAGES,v)

// PostgREST returns the RAISE text in `message`; permission errors (SQLSTATE 42501) mean the caller may not do it at all.
export function classifyTeamError(err:{message?:string;code?:string}|null|undefined):TeamErrorCode{
 const m=String(err?.message??'')
 if(err?.code==='42501'||/permission denied|row-level security/i.test(m))return 'not_authorized'
 for(const code of Object.keys(TEAM_ERROR_MESSAGES) as TeamErrorCode[]){
  if(code!=='unexpected'&&code!=='invalid_input'&&m.includes(code))return code
 }
 return 'unexpected'
}

const EMAIL=/^[^@\s]+@[^@\s]+$/
export function normalizeEmail(raw:unknown):string|null{
 const e=String(raw??'').trim().toLowerCase()
 return e.length>=3&&e.length<=254&&EMAIL.test(e)?e:null
}

export const AUDIT_LABEL:Record<string,string>={
 invite_created:'Convite criado',invite_revoked:'Convite cancelado',invite_accepted:'Convite aceito',
 member_role_changed:'Perfil alterado',member_deactivated:'Acesso desativado',member_reactivated:'Acesso reativado'
}

const UUID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const isUuid=(v:unknown):v is string=>typeof v==='string'&&UUID_RE.test(v)

// Supabase Auth reports an already registered address as email_exists (422). That is not a failure for us:
// the invitation row exists and the person accepts it after logging in.
export function isExistingUserError(err:{message?:string;code?:string;status?:number}|null|undefined):boolean{
 return !!err&&(err.code==='email_exists'||err.code==='user_already_exists'||/already (been )?registered|already exists/i.test(String(err.message??'')))
}
