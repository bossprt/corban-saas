'use client'

// Opens the browser's print dialog (print or save as PDF). Hidden in the printout itself.
export function PrintButton({ className, label = 'Imprimir / PDF' }: { className?: string; label?: string }) {
  return <button type="button" onClick={() => window.print()} className={className}>{label}</button>
}
