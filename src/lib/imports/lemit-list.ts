// Lemit "Não Perturbe SP" list (24/10/2026): a file of ~16 million lines "phone;created_at;valid_at". The browser reads it
// as a stream (plain .csv or the .zip as it comes from Lemit) and keeps only the area codes the company chose, so only a
// few thousand phones are sent. Pure helpers here; the reading itself is in the import screen.

export type LemitRow = { phone: string; valid_from: string | null }
export type LemitColumns = { phone: number; valid: number; delimiter: string }

// Header "phone;created_at;valid_at" (or similar names in Portuguese). Null when there is no phone column.
export function lemitColumns(header: string): LemitColumns | null {
  const delimiter = (header.match(/;/g)?.length ?? 0) >= (header.match(/,/g)?.length ?? 0) ? ';' : ','
  const cols = header.replace(/^﻿/, '').split(delimiter).map(c => c.trim().toLowerCase().replace(/"/g, ''))
  const phone = cols.findIndex(c => /^(phone|telefone|fone|celular|numero|número)$/.test(c))
  const valid = cols.findIndex(c => /valid|validade|vigencia|vigência/.test(c))
  return phone < 0 ? null : { phone, valid, delimiter }
}

// "68, 69 92" -> ["68","69","92"]; only two-digit area codes 11..99.
export function parseDdds(v: string): string[] {
  return [...new Set((v.match(/\d{2}/g) ?? []).filter(d => Number(d) >= 11))]
}

// Phone digits without the country code: "5568999990000" -> "68999990000"; anything that is not 10 or 11 digits -> null.
export function localPhone(v: string): string | null {
  let d = v.replace(/\D/g, '')
  if ((d.length === 12 || d.length === 13) && d.startsWith('55')) d = d.slice(2)
  return d.length === 10 || d.length === 11 ? d : null
}

// One line of the file, kept only when its area code is chosen. Dates "2026-10-24" (or "24/10/2026") become ISO.
export function lemitLine(line: string, cols: LemitColumns, ddds: Set<string>): LemitRow | null {
  const parts = line.split(cols.delimiter)
  const phone = localPhone(parts[cols.phone] ?? '')
  if (!phone || !ddds.has(phone.slice(0, 2))) return null
  const raw = cols.valid >= 0 ? (parts[cols.valid] ?? '').trim().replace(/"/g, '') : ''
  const iso = /^\d{4}-\d{2}-\d{2}/.test(raw) ? raw.slice(0, 10) : /^\d{2}\/\d{2}\/\d{4}/.test(raw) ? raw.slice(0, 10).split('/').reverse().join('-') : null
  return { phone, valid_from: iso }
}

// Where the first file of a .zip starts and how it is stored, from the zip's central directory (end of the file).
export type ZipEntry = { dataStart: number; compressedSize: number; uncompressedSize: number; method: number; name: string }
export async function firstZipEntry(file: Blob): Promise<ZipEntry | null> {
  const tailSize = Math.min(file.size, 65_557)
  const tail = new DataView(await file.slice(file.size - tailSize).arrayBuffer())
  let eocd = -1
  for (let i = tail.byteLength - 22; i >= 0; i--) if (tail.getUint32(i, true) === 0x06054b50) { eocd = i; break }
  if (eocd < 0) return null
  const cdOffset = tail.getUint32(eocd + 16, true)
  const cd = new DataView(await file.slice(cdOffset, cdOffset + 46 + 1024).arrayBuffer())
  if (cd.getUint32(0, true) !== 0x02014b50) return null
  const method = cd.getUint16(10, true)
  const compressedSize = cd.getUint32(20, true)
  const uncompressedSize = cd.getUint32(24, true)
  const nameLen = cd.getUint16(28, true)
  const localOffset = cd.getUint32(42, true)
  const name = new TextDecoder().decode(new Uint8Array(cd.buffer, 46, Math.min(nameLen, cd.byteLength - 46)))
  const local = new DataView(await file.slice(localOffset, localOffset + 30).arrayBuffer())
  if (local.getUint32(0, true) !== 0x04034b50) return null
  const dataStart = localOffset + 30 + local.getUint16(26, true) + local.getUint16(28, true)
  return { dataStart, compressedSize, uncompressedSize, method, name }
}
