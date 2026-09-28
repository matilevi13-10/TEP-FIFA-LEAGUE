#!/usr/bin/env python3
"""
Generates 003_league_rules.sql from schema.sql, so the latest migration and the
fresh-install schema can never describe different databases. Re-run this after
editing schema.sql:  python3 supabase/migrations/build_003.py

002_accounts_and_chat.sql is frozen: it was generated the same way, but its
structure section predates 003, so regenerating it now would break it.
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parents[2]
schema = (root / 'supabase' / 'schema.sql').read_text()

RULE = '-- ' + '-' * 75
start = schema.index(RULE + '\n-- Identity helpers')
end = schema.index(RULE + '\n-- Seed: just the league row.')
body = schema[start:end].rstrip() + '\n'

# Policies are CREATE-only in the schema; the migration has to be re-runnable.
body = re.sub(
    r'^create policy (\w+)\s+on (\S+)',
    lambda m: f'drop policy if exists {m.group(1)} on {m.group(2)};\ncreate policy {m.group(1)} on {m.group(2)}',
    body, flags=re.M)

header = pathlib.Path(root / 'supabase' / 'migrations' / '_003_head.sql').read_text()
footer = pathlib.Path(root / 'supabase' / 'migrations' / '_003_tail.sql').read_text()

out = header + '\n' + body + '\n' + footer
target = root / 'supabase' / 'migrations' / '003_league_rules.sql'
target.write_text(out)
print(f'wrote {target.relative_to(root)} — {len(out.splitlines())} lines')
