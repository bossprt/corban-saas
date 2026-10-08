// Where a form returns after saving, when sent from the lead panel in Vendas: only a Vendas path with a plain query
// (ids, tab, filters), never an external address.
export function crmBack(v: unknown): string | null {
  const s = String(v ?? '')
  return /^\/app\/crm(\/[\w-]+)*(\?[\w=&%:.-]*)?$/.test(s) ? s : null
}
