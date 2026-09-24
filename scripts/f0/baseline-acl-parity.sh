#!/bin/bash
# Prints SQL that makes the privileges of a database freshly restored from the production baseline equal to production.
#
# Why: pg_dump writes only the final GRANT/REVOKE list of each object. When the baseline is restored into a Supabase
# database, the platform's default privileges first grant every new table and function to anon, authenticated and
# service_role, and nothing in the dump takes those grants back. Locally, anon could then execute ~90 functions and
# read and write 60 tables that production denies. Revoking what the defaults added and replaying the dump's own
# GRANT/REVOKE statements restores production's privileges exactly.
#
# Run it right after the baseline and before any later migration (later migrations carry their own revokes):
#   bash scripts/f0/baseline-acl-parity.sh | psql -v ON_ERROR_STOP=1 ...
set -euo pipefail
baseline="$(dirname "$0")/../../supabase/baseline/20260924_prod_schema_baseline.sql"
echo "begin;"
for schema in public private; do
  for kind in tables sequences functions; do
    echo "revoke all on all $kind in schema $schema from anon, authenticated, service_role;"
  done
done
grep -E '^(GRANT|REVOKE) ' "$baseline"
echo "commit;"
