#!/usr/bin/env bash
# Runs the schema and its tests against a throwaway local Postgres, so you can
# change schema.sql without guessing. Needs postgresql@16 (brew install postgresql@16).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
DATA=$(mktemp -d)/pg
SOCK=/tmp/tep-test-pg
mkdir -p "$SOCK"
trap 'pg_ctl -D "$DATA" stop -m immediate >/dev/null 2>&1 || true' EXIT

initdb -D "$DATA" -U postgres --auth=trust >/dev/null
pg_ctl -D "$DATA" -o "-p 55432 -k $SOCK -c listen_addresses=''" -l "$DATA/pg.log" start >/dev/null
sleep 2
P="psql -h $SOCK -p 55432 -U postgres -v ON_ERROR_STOP=1 -q"

$P -f supabase/tests/00_supabase_stub.sql 2>&1 | grep -Ev 'WARNING|HINT' || true
$P -d tep -f supabase/schema.sql 2>&1 | grep -Ev 'NOTICE|^$' || true
for t in supabase/tests/0[123]_*.sql; do
  echo "── $(basename "$t")"
  $P -d tep -f "$t" 2>&1 | grep -E 'NOTICE:  ok|FAILED|ERROR' | sed 's/^.*NOTICE:  /  /'
done
echo "All checks passed."
