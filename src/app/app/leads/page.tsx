import { redirect } from 'next/navigation'

// The old flat lead list became the Vendas board (sales CRM v2).
export default function LeadsPage() {
  redirect('/app/crm')
}
