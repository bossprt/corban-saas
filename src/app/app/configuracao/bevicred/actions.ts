'use server'

import { requireAppContext } from '@/lib/appContext'
import { BEVICRED_ORGANIZATION_ID, PROBE_TEXT } from '@/lib/bevicred'
import { probeBevicred } from '@/lib/bevicred.server'

export type ProbeState = { ok?: boolean; message?: string; at?: string }

// Admin only, Smart only. Shows whether the token request worked; never the token, the key or the partner code.
export async function testBevicred(): Promise<ProbeState> {
  const { membership, organization } = await requireAppContext()
  if (membership.role !== 'admin' || organization.id !== BEVICRED_ORGANIZATION_ID) return { ok: false, message: 'Somente o administrador da empresa testa esta conexão.' }
  const r = await probeBevicred()
  const at = new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })
  if (r.ok) return { ok: true, message: `Conectou: a Bevicred aceitou o acesso e entregou o token (${r.ms} ms).`, at }
  return { ok: false, message: `${PROBE_TEXT[r.reason]}${r.detail ? ` Resposta: ${r.detail}.` : ''}`, at }
}
