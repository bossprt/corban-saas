// Everything the company registers lives under one menu item, "Cadastros" (owner decision 25/09/2026): the side menu lists
// these entries under it and the hub page shows them as cards. Clients stay a separate item (daily work, not setup).
export type Registration = { href: string; label: string; hint: string; teamOnly?: boolean }

export const REGISTRATIONS: Registration[] = [
  { href: '/app/comercial/instituicoes', label: 'Bancos', hint: 'Bancos com que a empresa trabalha, IR retido na fonte e se paga imposto (pelas tabelas).' },
  { href: '/app/comercial/convenios', label: 'Convênios', hint: 'Convênios nacionais habilitados e convênios próprios.' },
  { href: '/app/comercial/origens', label: 'Promotoras parceiras', hint: 'Masters, promotoras e correspondentes por onde a empresa também digita.' },
  { href: '/app/comercial/tipos-contrato', label: 'Tipos de contrato', hint: 'Novo, Refinanciamento, Portabilidade e tipos próprios.' },
  { href: '/app/comercial/tabelas', label: 'Tabelas', hint: 'Tabelas de comissão, versões, condições e importação.' },
  { href: '/app/comercial/grupos', label: 'Grupos de vendedores', hint: 'Corretor, Parceiro, Balcão...: a regra de repasse de cada tipo de vendedor.' },
  { href: '/app/cadastros/vendedores', label: 'Vendedores', hint: 'Cada vendedor, o grupo dele e a categoria PF/PJ/SUB.' },
  { href: '/app/comercial/fatores', label: 'Fatores', hint: 'Fatores diários e fixos usados nas simulações.' },
  { href: '/app/equipe', label: 'Equipe', hint: 'Quem acessa o sistema, convites e o papel de cada pessoa.', teamOnly: true },
]

// Pages that belong to the Cadastros section (the menu item stays highlighted and open on them).
export const REGISTRATION_SECTIONS = ['/app/cadastros', '/app/comercial', '/app/equipe']
