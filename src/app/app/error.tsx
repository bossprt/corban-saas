'use client'

import { ErrorNotice } from '@/components/shell/ErrorNotice'

// Last-resort boundary inside the app (keeps the menu around it).
export default function AppError({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  return <ErrorNotice digest={error.digest} retry={retry} />
}
