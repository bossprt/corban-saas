'use client'

import { Download } from 'lucide-react'

// Campaign spreadsheet template, built in the browser (no personal data: titles and instructions only).
export const TEMPLATE_HEADERS = ['Nome', 'CPF', 'Telefone', 'Telefone 2', 'E-mail', 'Margem', 'Banco', 'Matrícula / Benefício', 'Convênio', 'Salário', 'Observação']
const INSTRUCTIONS = [
  ['Como preencher a planilha da campanha'],
  [''],
  ['Obrigatório: Nome e pelo menos o CPF ou um Telefone com DDD.'],
  ['CPF com ou sem pontos. Se o CPF já for cliente, o lead fica ligado à ficha dele, sem duplicar.'],
  ['Telefone com DDD, ex.: (68) 99999-0000. Telefone 2 é opcional.'],
  ['As outras colunas (Margem, Banco, Matrícula, Convênio, Salário, Observação) aparecem para o vendedor na ficha do lead.'],
  ['Pode apagar as colunas que não usar ou criar outras: na hora de importar você marca quais o vendedor vai ver.'],
  ['A mesma pessoa duas vezes na campanha (mesmo CPF ou telefone) entra uma vez só.'],
  ['Até 20.000 linhas por arquivo.'],
]

export function TemplateDownload({ className }: { className?: string }) {
  async function download() {
    const XLSX = await import('@e965/xlsx')
    const wb = XLSX.utils.book_new()
    const leads = XLSX.utils.aoa_to_sheet([TEMPLATE_HEADERS])
    leads['!cols'] = TEMPLATE_HEADERS.map(h => ({ wch: Math.max(14, h.length + 4) }))
    // CPF and phones as text, so a leading zero is never lost.
    for (const col of ['B', 'C', 'D']) for (let r = 2; r <= 2000; r++) leads[`${col}${r}`] = { t: 's', v: '', z: '@' }
    leads['!ref'] = `A1:K2000`
    XLSX.utils.book_append_sheet(wb, leads, 'Leads')
    const help = XLSX.utils.aoa_to_sheet(INSTRUCTIONS)
    help['!cols'] = [{ wch: 110 }]
    XLSX.utils.book_append_sheet(wb, help, 'Instruções')
    XLSX.writeFile(wb, 'modelo-campanha-corban.xlsx')
  }
  return (
    <button type="button" onClick={download} className={className ?? 'inline-flex h-10 items-center gap-2 rounded-[10px] border border-line bg-surface px-4 text-sm font-medium text-ink hover:bg-surface-muted'}>
      <Download size={16} aria-hidden />Baixar modelo em Excel
    </button>
  )
}
