// Moving a proposal to these stages needs a reason (audit 06/11/2026, E7 and owner approval): the reason of a Pendência
// is what Contratos shows on the "Pendência" label, and Recusada / Cancelada close the contract, so they ask for a
// confirmation and say why. The reason goes to the stage history (move_case_to_stage note).
export const REASON_STATES = ['pending_external', 'rejected', 'cancelled'] as const

export const needsReason = (canonicalState: string | null | undefined) => (REASON_STATES as readonly string[]).includes(canonicalState ?? '')
// Recusada and Cancelada close the contract: the dialog says so and asks to confirm.
export const closesContract = (canonicalState: string | null | undefined) => canonicalState === 'rejected' || canonicalState === 'cancelled'

export const REASON_MIN = 3
export const REASON_MAX = 500

// A typed reason that is good enough: at least 3 characters once trimmed, at most 500.
export const validReason = (note: string) => { const t = note.trim(); return t.length >= REASON_MIN && t.length <= REASON_MAX }
