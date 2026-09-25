'use client'

import { useRef, useState } from 'react'
import { applyLookup, EMPTY_ADDRESS, normalizeCep, type AddressFields as Fields, type AddressKey, type CepLookup } from '@/lib/cep'

const field = 'field'
const MSG: Record<string, string> = {
  found: 'Endereço encontrado. Confira e informe o número.',
  not_found: 'CEP não encontrado. Preencha o endereço à mão.',
  invalid: 'CEP inválido. Use 8 dígitos.',
  unavailable: 'Consulta indisponível agora. Preencha o endereço à mão; você pode salvar do mesmo jeito.',
}

// Address block with CEP autofill. The lookup is a suggestion: it never blocks the form, never replaces what the person already typed, and number/complement stay manual.
// `prefix` names the inputs ("business_zip"...) so one form can carry two addresses; `legend` titles the block.
export function AddressFields({ initial, prefix = '', legend = 'Endereço (opcional)' }: { initial?: Partial<Fields>; prefix?: string; legend?: string }) {
  const [v, setV] = useState<Fields>({ ...EMPTY_ADDRESS, ...initial })
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  // values that were already saved count as the person's own: a lookup never replaces them silently
  const touched = useRef(new Set<AddressKey>((Object.entries(initial ?? {}) as [AddressKey, string | undefined][]).filter(([, x]) => !!x?.trim()).map(([k]) => k)))
  const last = useRef<string | null>(null)

  const set = (k: AddressKey, value: string) => { touched.current.add(k); setV(p => ({ ...p, [k]: value })) }

  async function lookup(raw: string) {
    const cep = normalizeCep(raw)
    if (!cep) { setMsg(raw.trim() ? MSG.invalid : null); return }
    if (last.current === cep) return
    last.current = cep
    setBusy(true); setMsg(null)
    try {
      const res = await fetch(`/api/cep?cep=${cep}`, { cache: 'no-store' })
      const r = (await res.json()) as CepLookup
      if (r.kind === 'found') {
        // the CEP field itself counts as typed: filling the address must not depend on it
        setV(p => applyLookup(p, touched.current, r.address))
      }
      setMsg(MSG[r.kind] ?? MSG.unavailable)
    } catch {
      setMsg(MSG.unavailable)
    } finally { setBusy(false) }
  }

  return <fieldset className="grid gap-2 md:col-span-5 md:grid-cols-6">
    <legend className="mb-1 text-xs text-muted">{legend}</legend>
    <input name={`${prefix}zip`} inputMode="numeric" autoComplete="postal-code" placeholder="CEP" value={v.zip} maxLength={9} className={field}
      onChange={e => { setV(p => ({ ...p, zip: e.target.value })); if (normalizeCep(e.target.value)) void lookup(e.target.value) }} onBlur={e => void lookup(e.target.value)} />
    <input name={`${prefix}street`} placeholder="Rua / logradouro" value={v.street} maxLength={160} className={`${field} md:col-span-3`} onChange={e => set('street', e.target.value)} />
    <input name={`${prefix}number`} placeholder="Número" value={v.number} maxLength={20} className={field} onChange={e => set('number', e.target.value)} />
    <input name={`${prefix}complement`} placeholder="Complemento" value={v.complement} maxLength={80} className={field} onChange={e => set('complement', e.target.value)} />
    <input name={`${prefix}district`} placeholder="Bairro" value={v.district} maxLength={120} className={`${field} md:col-span-2`} onChange={e => set('district', e.target.value)} />
    <input name={`${prefix}city`} placeholder="Cidade" value={v.city} maxLength={120} className={`${field} md:col-span-2`} onChange={e => set('city', e.target.value)} />
    <input name={`${prefix}state`} placeholder="UF" value={v.state} maxLength={2} className={field} onChange={e => set('state', e.target.value.toUpperCase())} />
    <p aria-live="polite" className="text-xs text-muted md:col-span-6">{busy ? 'Buscando CEP...' : msg ?? 'Digite o CEP para preencher rua, bairro, cidade e UF automaticamente.'}</p>
  </fieldset>
}
