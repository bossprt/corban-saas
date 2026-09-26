// The Supabase API returns at most 1000 rows per request. Screens that need every row (a 121-line table has ~1800
// group values; the company has 1600+ table lines) read page by page until a short page comes back.
// `page(from, to)` must build a fresh query with a stable order and `.range(from, to)`.
export async function fetchAll<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: unknown }>, pageSize = 1000, maxRows = 50_000): Promise<T[]> {
  const out: T[] = []
  for (let from = 0; from < maxRows; from += pageSize) {
    const { data, error } = await page(from, from + pageSize - 1)
    if (error) throw error
    out.push(...(data ?? []))
    if (!data || data.length < pageSize) break
  }
  return out
}
