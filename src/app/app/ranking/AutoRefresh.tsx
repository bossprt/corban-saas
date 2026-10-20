'use client'

import { useEffect } from 'react'
import { useRouter } from 'next/navigation'

// TV mode: the board refreshes itself every minute.
export function AutoRefresh({ seconds = 60 }: { seconds?: number }) {
  const router = useRouter()
  useEffect(() => {
    const t = setInterval(() => router.refresh(), seconds * 1000)
    return () => clearInterval(t)
  }, [router, seconds])
  return null
}
