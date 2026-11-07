'use client'

import { useState } from 'react'

const label = 'grid gap-1.5 text-[13px] font-medium text-ink-soft'

// "De" and "Até" of the report: "Até" cannot come before "De" (the print page answered with a 404 in English).
export function PeriodFields({ from, to }: { from: string; to: string }) {
  const [de, setDe] = useState(from)
  const [ate, setAte] = useState(to)
  const wrong = !!de && !!ate && ate < de
  return (
    <>
      <label className={label}>De<input type="date" name="de" required value={de} onChange={e => setDe(e.target.value)} className="field" /></label>
      <label className={label}>Até<input type="date" name="ate" required min={de || undefined} value={ate} onChange={e => setAte(e.target.value)}
        aria-invalid={wrong} aria-describedby={wrong ? 'periodo-erro' : undefined} className="field" /></label>
      {wrong && <p id="periodo-erro" role="alert" className="basis-full text-sm text-[#991B1B]">A data &quot;Até&quot; precisa ser igual ou depois de &quot;De&quot;.</p>}
    </>
  )
}
