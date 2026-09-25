# Exports the production schema (structure only, no data) for the F0 baseline.
# Read-only on the database. The password is typed into a hidden prompt, kept only in this
# process's memory and cleared at the end. Nothing is written to the repository.
#
# Run from the project folder in PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\f0\export-baseline.ps1

$ErrorActionPreference = 'Stop'
$ref = 'nhjfrcttzxnphhizlnmc'
$pgDump = 'C:\Program Files\PostgreSQL\18\bin\pg_dump.exe'
$out = Join-Path $env:TEMP 'corban_baseline.sql'

$secure = Read-Host -AsSecureString 'Senha do banco do Supabase (nada aparece enquanto digita; Enter no fim)'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  $env:PGSSLMODE = 'require'
  # Session pooler hosts for sa-east-1, then the direct host.
  $targets = @(
    @{ Host = 'aws-0-sa-east-1.pooler.supabase.com'; User = "postgres.$ref" },
    @{ Host = 'aws-1-sa-east-1.pooler.supabase.com'; User = "postgres.$ref" },
    @{ Host = "db.$ref.supabase.co"; User = 'postgres' }
  )
  $done = $false
  foreach ($t in $targets) {
    Write-Host "Tentando $($t.Host)..."
    & $pgDump -h $t.Host -p 5432 -U $t.User -d postgres --schema-only --schema=public --no-owner -f $out 2>$null
    if ($LASTEXITCODE -eq 0) { $done = $true; break }
  }
  if ($done) {
    Write-Host ''
    Write-Host 'BASELINE_OK' -ForegroundColor Green
    # Production-only migrations: exact bytes via base64, verified against the md5 manifest.
    $psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
    $root = Split-Path (Split-Path $PSScriptRoot)
    $ok = 0; $bad = 0
    foreach ($line in Get-Content (Join-Path $PSScriptRoot 'prod-migrations-manifest.txt')) {
      if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
      $version, $name, $expected = $line.Trim() -split '\s+'
      $file = Join-Path $root "supabase\migrations\${version}_${name}.sql"
      $b64 = & $psql -h $t.Host -p 5432 -U $t.User -d postgres -X -A -t -q -c "select encode(convert_to(array_to_string(statements, E'\n'), 'UTF8'), 'base64') from supabase_migrations.schema_migrations where version = '$version'"
      [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String(($b64 -join '')))
      $actual = (Get-FileHash -Algorithm MD5 $file).Hash.ToLower()
      if ($actual -eq $expected) { $ok++ } else { $bad++; Write-Host "FAIL $name" -ForegroundColor Red }
    }
    Write-Host "MIGRATIONS_OK $ok de $($ok + $bad)" -ForegroundColor Green
  } else {
    Write-Host ''
    Write-Host 'FALHOU: senha incorreta ou conexao bloqueada. Confira a senha e tente de novo.' -ForegroundColor Red
  }
} finally {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:PGSSLMODE -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
