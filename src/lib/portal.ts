// Broker portal (F7): a member with the 'corretor' role, while the company has the portal module, sees only the portal.
export const isPortalUser = (roleKey: string | undefined, modules: Set<string>) => roleKey === 'corretor' && modules.has('portal_corretor')

export const SUBMISSION_LABEL: Record<string, string> = { pending: 'Aguardando validação', validated: 'Validada', rejected: 'Recusada' }
