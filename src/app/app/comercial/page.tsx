import { redirect } from 'next/navigation'

// The old "Comercial" overview was replaced by the Cadastros hub (owner decision 25/09/2026); old links land there.
export default function CommercialPage() {
  redirect('/app/cadastros')
}
