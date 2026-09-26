import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { effectiveContractTypes } from '@/lib/contract-types'
import { SHEET_LINE_COLUMNS, SHEET_TAIL_COLUMNS, valueColumns } from '@/lib/commission/tableSheet'

export const dynamic='force-dynamic'

export async function GET(){
  const {supabase,membership,organization}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return new Response('Sem permissão',{status:403})

  const [groups,components,types,settings,rules]=await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('commission_component_types').select('id,tech_key,name,is_active,sort_order').eq('is_active',true).order('sort_order'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('commission_group_rules').select('group_id,version,own_production').order('version',{ascending:false}),
  ])
  // One block of columns per seller group that is paid (own production has no block: the company keeps everything).
  const own=new Map<string,boolean>()
  for(const r of (rules.data??[]) as {group_id:string;own_production:boolean}[])if(!own.has(r.group_id))own.set(r.group_id,r.own_production)
  const payGroups=(groups.data??[]).filter(g=>!own.get(g.id))

  const enabled=effectiveContractTypes(
    (types.data??[]) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[],
    (settings.data??[]) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[],
    'commission',
  )

  const wb=new ExcelJS.Workbook()
  const ws=wb.addWorksheet('Tabelas')
  // Same layout as the 2tech report: company block, then one block per group. Number = % of the operation; "R$ 25,00" = fixed.
  const columns:string[]=[...SHEET_LINE_COLUMNS,'Fator','Taxa a.m. (%)',...SHEET_TAIL_COLUMNS,...valueColumns(components.data??[],payGroups)]
  ws.addRow(columns)
  ws.views=[{state:'frozen',ySplit:1}]
  ws.autoFilter={from:'A1',to:ws.getRow(1).getCell(columns.length).address}
  ws.getRow(1).font={bold:true}
  ws.columns=columns.map((h,i)=>({key:String(i),width:Math.min(42,Math.max(16,h.length+2))}))

  const guide=wb.addWorksheet('Instruções')
  guide.addRows([
    ['Corban — modelo de importação de tabelas'],
    ['Empresa',organization.name],
    ['Colunas','Dados da linha, depois o bloco (Empresa) com o que o banco paga e um bloco para cada grupo de vendedores com o que ele recebe.'],
    ['Valores','Número = % da operação (ex.: 2,5). "R$ 25,00" = valor fixo por contrato. Vazio = não vale para aquele grupo na linha.'],
    ['Base de Cálculo','Bruto (valor do contrato) ou Líquido (valor liberado): sobre qual valor os % da linha são calculados.'],
    ['Imposto (%)','Imposto que a empresa paga sobre o que recebe nesta linha (média do Simples, ex.: 6). Vazio ou 0 = não paga imposto. O vendedor nunca paga imposto.'],
    ['Tipo de Contrato','Use exatamente um dos nomes habilitados abaixo.'],
    ['Grupos','Só grupos cadastrados. Coluna de grupo desconhecido faz a planilha ser recusada inteira. Produção própria não tem bloco.'],
    ['Planilha da 2tech','Pode ser importada como está: o Corban pergunta de qual grupo é cada "Repasse N".'],
    ['Segurança','Antes de gravar, o Corban mostra a prévia. Tudo entra como rascunho para você conferir e publicar.'],
    [],
    ['Tipos de Contrato habilitados'],
    ...enabled.map(t=>[t.name]),
    [],
    ['Grupos de vendedores com bloco'],
    ...payGroups.map(g=>[g.name]),
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
