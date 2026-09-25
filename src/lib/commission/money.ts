// Exact decimal arithmetic on rationals (BigInt). Money never touches floating point.
export type Rational={n:bigint;d:bigint}

// BigInt literals (0n) need target ES2020; the app targets ES2017, so constants are built with BigInt().
const Z=BigInt(0),ONE=BigInt(1),TWO=BigInt(2),TEN=BigInt(10)
const gcd=(a:bigint,b:bigint):bigint=>{a=a<Z?-a:a;b=b<Z?-b:b;while(b!==Z){[a,b]=[b,a%b]}return a}
const norm=(n:bigint,d:bigint):Rational=>{
 if(d===Z)throw new Error('division_by_zero')
 if(d<Z){n=-n;d=-d}
 const g=gcd(n,d)||ONE
 return {n:n/g,d:d/g}
}

export function fromDecimalString(v:string):Rational{
 const m=/^(-?)(\d+)(?:\.(\d+))?$/.exec(v.trim())
 if(!m)throw new Error(`invalid_decimal:${v}`)
 const frac=m[3]??''
 const n=BigInt(m[2]+frac)*(m[1]?-ONE:ONE)
 return norm(n,TEN**BigInt(frac.length))
}
export const add=(a:Rational,b:Rational)=>norm(a.n*b.d+b.n*a.d,a.d*b.d)
export const sub=(a:Rational,b:Rational)=>norm(a.n*b.d-b.n*a.d,a.d*b.d)
export const mul=(a:Rational,b:Rational)=>norm(a.n*b.n,a.d*b.d)
export const div=(a:Rational,b:Rational)=>norm(a.n*b.d,a.d*b.n)
export const isZero=(a:Rational)=>a.n===Z
export const cmp=(a:Rational,b:Rational)=>{const l=a.n*b.d,r=b.n*a.d;return l<r?-1:l>r?1:0}

// Round half away from zero to `scale` decimals and print as a plain decimal string.
export function toDecimalString(a:Rational,scale=2):string{
 const p=TEN**BigInt(scale)
 const neg=a.n<Z
 const abs=neg?-a.n:a.n
 const q=(abs*p*TWO+a.d)/(a.d*TWO)
 const s=q.toString().padStart(scale+1,'0')
 const int=s.slice(0,s.length-scale),frac=s.slice(s.length-scale)
 return `${neg&&/[1-9]/.test(int+frac)?'-':''}${int}${scale?'.'+frac:''}`
}
