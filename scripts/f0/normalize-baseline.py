# Normalizes a pg_dump (schema public) of production into a baseline that a clean Supabase accepts:
# drops psql-only \restrict lines and platform-owned default privileges, makes CREATE SCHEMA public
# idempotent, adds btree_gist and the private schema (captured separately). Usage: python normalize-baseline.py <file>
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.split("\n")
kept = [l for l in lines if not (l.startswith("\\restrict ") or l.startswith("\\unrestrict "))]
kept = [l for l in kept if not l.startswith("ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin")]
kept = ["CREATE SCHEMA IF NOT EXISTS public;" if l == "CREATE SCHEMA public;" else l for l in kept]
import os
if "CREATE SCHEMA IF NOT EXISTS private;" not in kept:
    block = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "private_schema.sql"), encoding="utf-8").read().split("\n")
    first_policy = next(i for i, l in enumerate(kept) if l.startswith("CREATE POLICY"))
    kept[first_policy:first_policy] = block + [""]
header ="create extension if not exists btree_gist with schema extensions;"
if kept[0] != header:
    kept.insert(0, header)
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(kept))
print(len(lines) - len(kept), "removed")
