#!/usr/bin/env bash
# Deterministically export production-only migrations into supabase/migrations and verify each one
# against the md5 manifest captured read-only on 2026-09-24. Read-only on the database.
#
# Usage (the connection string stays in your shell, never in the repo):
#   SUPABASE_DB_URL='postgresql://postgres.<ref>:<password>@<host>:5432/postgres' bash scripts/f0/fetch-prod-migrations.sh
set -euo pipefail
: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL (Supabase dashboard > Connect > Session pooler)}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/supabase/migrations"
fail=0
while read -r version name expected; do
  file="$out/${version}_${name}.sql"
  psql "$SUPABASE_DB_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
    -c "select array_to_string(statements, E'\n') from supabase_migrations.schema_migrations where version = '$version'" \
    | head -c -1 > "$file"   # psql adds one trailing newline
  actual="$(md5sum "$file" | cut -d' ' -f1)"
  if [ "$actual" = "$expected" ]; then echo "OK   $version $name"; else echo "FAIL $version $name ($actual)"; fail=1; fi
done < <(grep -v "^#" "$here/prod-migrations-manifest.txt")
exit $fail
