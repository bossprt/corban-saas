import type { NextRequest } from 'next/server'
import { NextResponse } from 'next/server'

// The tables search form goes through here (owner decision 26/09/2026): the filters are remembered in a cookie of that
// screen, so a table page's "Nova pesquisa" goes back to them. Only the known filters travel; nothing else is stored.
const SEARCH_COOKIE = 'tabelas_busca'
const KEYS = ['banco', 'convenio', 'nome', 'promotora', 'situacao', 'vigencia', 'tipo', 'codigo', 'n']
const BASE = '/app/comercial/tabelas'

export function GET(req: NextRequest) {
  const q = new URLSearchParams()
  for (const k of KEYS) { const v = req.nextUrl.searchParams.get(k)?.trim(); if (v) q.set(k, v.slice(0, 120)) }
  const target = q.size ? `${BASE}?${q.toString()}` : BASE
  const res = NextResponse.redirect(new URL(target, req.nextUrl.origin), 303)
  res.cookies.set(SEARCH_COOKIE, q.toString(), { path: BASE, httpOnly: true, sameSite: 'lax', secure: req.nextUrl.protocol === 'https:', maxAge: 60 * 60 * 12 })
  return res
}
