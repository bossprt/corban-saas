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
 invalid_password:'Senha inválida: use de 8 a 72 caracteres e repita igual no segundo campo.',
 already_member:'Este e-mail já é membro desta empresa. Para trocar a senha, use Redefinir senha no membro.',
 email_has_other_access:'Este e-mail já tem acesso a outra empresa no Corban. A pessoa entra com a senha dela; peça para usar "Esqueci minha senha" se precisar.',
 weak_length:'O serviço de login recusou a senha: é curta demais para as regras do sistema. Use uma senha maior.',
 weak_characters:'O serviço de login recusou a senha: ela precisa ter letra minúscula, letra maiúscula, número e símbolo (por exemplo, Smart#2026casa).',
 weak_pwned:'O serviço de login recusou a senha: ela aparece em listas de senhas vazadas na internet. Escolha outra, menos comum.',
 access_not_created:'O acesso não foi criado agora (o serviço de login recusou). Confira o e-mail e tente de novo.',
 unexpected:'Não foi possível concluir. Nada foi alterado; tente novamente.'
} as const
export type TeamErrorCode=keyof typeof TEAM_ERROR_MESSAGES
export const isTeamErrorCode=(v:unknown):v is TeamErrorCode=>typeof v==='string'&&Object.prototype.hasOwnProperty.call(TEAM_ERROR_MESSAGES,v)

export const TEAM_OK_MESSAGES={
 access_created:'Acesso criado. Passe o e-mail e a senha para a pessoa entrar.',
 access_created_change:'Acesso criado. Passe o e-mail e a senha para a pessoa; no primeiro acesso ela escolhe a própria senha.',
 password_set:'Senha redefinida. Passe a nova senha para a pessoa.',
 password_set_change:'Senha redefinida. No próximo acesso a pessoa escolhe a própria senha.',
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
 invite_created:'Convite criado',invite_revoked:'Convite cancelado',invite_accepted:'Acesso liberado',
 member_role_changed:'Perfil alterado',member_deactivated:'Acesso desativado',member_reactivated:'Acesso reativado',
 role_created:'Papel criado',api_key_created:'Chave de integração criada',api_key_revoked:'Chave de integração revogada',seller_created:'Vendedor cadastrado',seller_supervision_updated:'Supervisão do vendedor alterada',seller_user_binding_updated:'Acesso do vendedor ao sistema alterado',role_updated:'Papel alterado',member_access_role_changed:'Papel do membro alterado',member_hierarchy_changed:'Filial, equipe ou alcance alterados',member_password_set:'Senha redefinida'
}

const UUID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const isUuid=(v:unknown):v is string=>typeof v==='string'&&UUID_RE.test(v)

// Supabase Auth reports an already registered address as email_exists (422). That is not a failure for us:
// the invitation row exists and the person accepts it after logging in.

// Why Auth refused a password, from its answer (the project's password rules: minimum length, required kinds of
// characters, or a password found in known leaks). Only the reason goes back to the screen; never the password.
export type PasswordRefusal='weak_length'|'weak_characters'|'weak_pwned'
export function passwordRefusal(err:unknown):PasswordRefusal|null{
 const e=err as {code?:string;message?:string;reasons?:string[];weak_password?:{reasons?:string[]}}|null
 if(!e)return null
 const reasons=[...(e.reasons??[]),...(e.weak_password?.reasons??[])]
 const m=String(e.message??'')
 if(reasons.includes('pwned')||/known to be weak|pwned|leak/i.test(m))return 'weak_pwned'
 if(reasons.includes('characters')||/at least one character of each/i.test(m))return 'weak_characters'
 if(reasons.includes('length')||/at least \d+ characters/i.test(m))return 'weak_length'
 if(e.code==='weak_password')return 'weak_characters'
 return null
}

// Minimum typed in the app (owner decision 29/09/2026: 8). Supabase Auth may add its own rules; a refusal says why.
export const PASSWORD_MIN=8, PASSWORD_MAX=72
