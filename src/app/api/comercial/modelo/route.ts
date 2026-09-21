import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { effectiveContractTypes } from '@/lib/contract-types'

export const dynamic='force-dynamic'

export async function GET(){
  const {supabase,membership,organization}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return new Response('Sem permissão',{status:403})

  const [groups,components,types,settings]=await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('commission_component_types').select('id,tech_key,name,is_active,sort_order').eq('is_active',true).order('sort_order'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
  ])

  const enabled=effectiveContractTypes(
    (types.data??[]) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[],
    (settings.data??[]) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[],
    'commission',
  )

  const wb=new ExcelJS.Workbook()
  const ws=wb.addWorksheet('Importação inteligente')
  const columns:string[]=[
    'Banco / Instituição',
    'Convênio',
    'Produto / Tabela',
    'Código no Banco',
    'Vigência Inicial',
    'Vigência Final',
    'Tipo de Contrato',
    'Prazo Inicial',
    'Prazo Final',
    'Coeficiente',
    'Taxa a.m. (%)',
    'Base da Comissão [LÍQUIDO ou BRUTO]',
    'Comissão Empresa (%)',
  ]

  for(const g of groups.data??[]){
    columns.push(g.name)
  }
  ws.addRow(columns)
  ws.views=[{state:'frozen',ySplit:1}]
  ws.autoFilter={from:'A1',to:ws.getRow(1).getCell(columns.length).address}
  ws.getRow(1).font={bold:true}
  ws.columns=columns.map((h,i)=>({key:String(i),width:Math.min(42,Math.max(16,h.length+2))}))

  const guide=wb.addWorksheet('Instruções')
  guide.addRows([
    ['CORBAN OS — Modelo de importação inteligente'],
    ['Empresa',organization.name],
    ['Objetivo','Importar tabelas comerciais de forma legível, uma linha por condição.'],
    ['Tipo de Contrato','Use exatamente um dos nomes habilitados abaixo.'],
    ['Base da Comissão','Use LÍQUIDO ou BRUTO conforme a regra do banco para aquela tabela.'],
    ['Comissão Empresa','Informe o percentual que o banco repassa à empresa naquela condição.'],
    ['Grupos de Comissão','Cada grupo tem sua própria coluna. Preencha somente quando houver ajuste manual. Se a tabela usar uma política/regra padrão, deixe as colunas dos grupos vazias para o Corban calcular.'],
    ['Percentuais','Use valores como 15.00, 9.50, 0.89. O sistema apresenta percentuais com duas casas decimais.'],
    ['Segurança','Antes de gravar, o Corban mostrará prévia e conflitos.'],
    [],
    ['Tipos de Contrato habilitados'],
    ...enabled.map(t=>[t.name]),
    [],
    ['Grupos de Comissão ativos'],
    ...(groups.data??[]).map(g=>[g.name]),
  ])
  guide.getColumn(1).width=34
  guide.getColumn(2).width=90
  guide.getRow(1).font={bold:true}

  const buffer=await wb.xlsx.writeBuffer()
  const safe=organization.name.normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-zA-Z0-9]+/g,'-').replace(/^-|-$/g,'').toLowerCase()||'organizacao'
  return new Response(buffer as ArrayBuffer,{
    headers:{
      'Content-Type':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition':`attachment; filename="corban-modelo-importacao-${safe}.xlsx"`,
      'Cache-Control':'no-store',
    }
  })
}
