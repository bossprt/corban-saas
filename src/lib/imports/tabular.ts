function splitCsvLine(line:string,delimiter:string){
 const out:string[]=[];let cur='';let quoted=false
 for(let i=0;i<line.length;i++){const ch=line[i];if(ch==='"'){if(quoted&&line[i+1]==='"'){cur+='"';i++}else quoted=!quoted}else if(ch===delimiter&&!quoted){out.push(cur.trim());cur=''}else cur+=ch}
 out.push(cur.trim());return out
}
export function parseCsv(text:string){
 const lines=text.replace(/^\uFEFF/,'').split(/\r?\n/).filter(x=>x.trim())
 if(lines.length<2)throw new Error('csv_without_rows')
 const delimiter=(lines[0].match(/;/g)?.length??0)>(lines[0].match(/,/g)?.length??0)?';':','
 const headers=splitCsvLine(lines[0],delimiter)
 return lines.slice(1).map(line=>Object.fromEntries(headers.map((h,i)=>[h,splitCsvLine(line,delimiter)[i]??''])))
}
function decodeEntities(s:string){return s.replace(/&nbsp;/gi,' ').replace(/&amp;/gi,'&').replace(/&lt;/gi,'<').replace(/&gt;/gi,'>').replace(/&#(\d+);/g,(_,n)=>String.fromCharCode(Number(n))).trim()}
export function parseHtmlTable(text:string){
 const rows=[...text.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map(m=>[...m[1].matchAll(/<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c=>decodeEntities(c[1].replace(/<[^>]+>/g,' '))))
 if(rows.length<2)throw new Error('html_table_without_rows')
 const headerIndex=rows.findIndex(r=>r.length>=3)
 const headers=rows[headerIndex]
 return rows.slice(headerIndex+1).filter(r=>r.length>=headers.length/2).map(r=>Object.fromEntries(headers.map((h,i)=>[h,r[i]??''])))
}
