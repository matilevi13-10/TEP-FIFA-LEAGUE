-- Read-only. Run this BEFORE the migration to see exactly which teams and
-- players are affected by removing placeholder players.
--
-- A "placeholder" is a players row with no user_id: a name somebody typed for a
-- teammate who never signed up.
--   • Placeholders with no team are deleted by the migration (nothing refers to
--     them, and they squat on usernames real people may want).
--   • Placeholders ON a team are LEFT ALONE and reported, because deleting one
--     would silently halve a team that may already have played matches.

select
  coalesce(t.name, '(no team — will be deleted)') as team,
  p.name                                          as placeholder,
  p.slot,
  (select string_agg(o.name, ' + ' order by o.slot)
     from public.players o where o.team_id = t.id) as full_roster,
  (select count(*) from public.matches m
    where m.team_a = t.id or m.team_b = t.id)      as matches_played,
  case when t.id is null then 'deleted by migration'
       else 'KEPT — your decision' end             as what_happens
from public.players p
left join public.teams t on t.id = p.team_id
where p.user_id is null
order by (t.id is null), t.name, p.slot;

-- Nothing returned means there are no placeholders and nothing to decide.
