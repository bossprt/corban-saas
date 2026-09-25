// Organization roles and permissions (migration 20260924071259_organization_roles_permissions_v1).
// The database is the authority (public.has_permission, RLS); this mirrors it so screens and actions fail early.
// MODULES × ACTIONS must stay identical to private.permission_catalog(); a unit test pins it.

export const MODULES = ['clientes', 'leads', 'propostas', 'esteira', 'comercial', 'financeiro', 'repasse', 'relatorios', 'equipe', 'configuracoes', 'integracoes'] as const
export const ACTIONS = ['view', 'create', 'edit', 'approve'] as const
export type Module = (typeof MODULES)[number]
export type Action = (typeof ACTIONS)[number]
export type Permission = `${Module}.${Action}`

export const MODULE_LABEL: Record<Module, string> = {
  clientes: 'Clientes',
  leads: 'Leads',
  propostas: 'Propostas',
  esteira: 'Esteira',
  comercial: 'Comercial (bancos, tabelas, regras)',
  financeiro: 'Financeiro',
  repasse: 'Repasse',
  relatorios: 'Relatórios',
  equipe: 'Equipe',
  configuracoes: 'Configurações',
  integracoes: 'Integrações',
}
export const ACTION_LABEL: Record<Action, string> = { view: 'Ver', create: 'Criar', edit: 'Editar', approve: 'Aprovar' }

export type Scope = 'own' | 'team' | 'branch' | 'all'
export const SCOPES: readonly Scope[] = ['own', 'team', 'branch', 'all']
export const SCOPE_LABEL: Record<Scope, string> = { own: 'Só o próprio', team: 'A equipe', branch: 'A filial', all: 'Toda a empresa' }

export type Tier = 'admin' | 'manager' | 'supervisor' | 'agent'
export const TIER_LABEL: Record<Tier, string> = { admin: 'Administrador', manager: 'Gerente', supervisor: 'Supervisor', agent: 'Básico' }

export type Access = { roleId: string; roleKey: string; roleName: string; tier: Tier; scope: Scope; permissions: ReadonlySet<string> }

export const ALL_PERMISSIONS: readonly Permission[] = MODULES.flatMap(m => ACTIONS.map(a => `${m}.${a}` as Permission))
export const isPermission = (v: unknown): v is Permission => typeof v === 'string' && (ALL_PERMISSIONS as readonly string[]).includes(v)
export const isScope = (v: unknown): v is Scope => typeof v === 'string' && (SCOPES as readonly string[]).includes(v)

// Fail closed: no access loaded means no permission.
export function can(access: Access | null | undefined, permission: Permission): boolean {
  return !!access && (access.tier === 'admin' || access.permissions.has(permission))
}

// Modules the platform switches per company (plans). MUST match private.module_catalog(); a unit test pins it.
export const PLAN_MODULES = [...MODULES, 'portal_corretor', 'campanhas', 'ia', 'api'] as const
export type PlanModule = (typeof PLAN_MODULES)[number]
export const PLAN_MODULE_LABEL: Record<PlanModule, string> = {
  ...MODULE_LABEL,
  comercial: 'Comercial',
  portal_corretor: 'Portal do corretor',
  campanhas: 'Campanhas (SMS/URA)',
  ia: 'Assistente de IA',
  api: 'API pública',
}
export const isPlanModule = (v: unknown): v is PlanModule => typeof v === 'string' && (PLAN_MODULES as readonly string[]).includes(v)
