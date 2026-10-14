#!/bin/bash
# Rebuilds the LOCAL test database (Docker container supabase_db_corban-f0-local) from scratch:
# production schema baseline (24/09/2026) + ACL parity + reference data + storage, then every migration after the
# baseline, in order. Data migrations written for a production company (Smart / MAIS VALOR ids) that fail because that
# company does not exist locally are skipped and listed. Never point this at production.
# Afterwards: load the test company (supabase/seed/f0-test-tenant.sql with `set corban.env = 'test'`) and the test users.
#   bash scripts/f0/rebuild-local.sh
set -e
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
C=supabase_db_corban-f0-local
P="docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
log="${TMPDIR:-${TEMP:-/tmp}}/corban-rebuild.log"
$P -c "drop schema if exists backup_c4 cascade; drop schema if exists backup_c5 cascade; drop schema if exists backup_c6 cascade;
       drop schema if exists private cascade; drop schema if exists public cascade;" > /dev/null 2>&1
$P -c "delete from storage.buckets where id = 'corban-documents';" > /dev/null 2>&1 || true
$P -1 < supabase/baseline/20260924_prod_schema_baseline.sql > "$log" 2>&1 || { tail -5 "$log"; exit 1; }
bash scripts/f0/baseline-acl-parity.sh | $P -1 > /dev/null
$P -1 < supabase/baseline/20260924_prod_reference_data.sql > /dev/null
$P -1 < supabase/baseline/20260924_prod_storage.sql > /dev/null 2>&1
n=0
for f in $(ls supabase/migrations | grep -E '^[0-9]{14}_' | sort); do
  # The baseline already holds everything before this version.
  if [[ "${f:0:14}" < "20260924063004" ]]; then continue; fi
  if ! $P -1 < "supabase/migrations/$f" > "$log" 2>&1; then
    if grep -qE "62405e20-af29-4359-b39c-79c206146b6c|4526e6a9-104e-4bad-9b0c-8deec89ca0d3" "supabase/migrations/$f"; then
      echo "skipped (production company data): $f"; continue
    fi
    echo "FAILED $f"; grep -E "ERROR|CONTEXT" "$log" | head -5; exit 1
  fi
  n=$((n+1))
done
echo "migrations applied: $n"
