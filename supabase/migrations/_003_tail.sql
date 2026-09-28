-- ---------------------------------------------------------------------------
-- 3. Rebuild an unplayed schedule in the weekly format
-- ---------------------------------------------------------------------------

do $$
declare made int;
begin
  if (select season_started_at is not null and phase = 'league'
        from public.league_settings where id = 1)
     and not exists (select 1 from public.matches where status = 'confirmed') then
    made := public.generate_schedule();
    raise notice 'Nothing had been played yet, so the schedule was rebuilt: % games.', made;
  elsif exists (select 1 from public.matches where phase = 'league' and status = 'confirmed') then
    raise notice 'Results already exist, so the current schedule was kept as it is.';
  end if;
end $$;

commit;

do $$
begin
  raise notice '=================================================';
  raise notice ' Migration 003 complete — the league rules are in.';
  raise notice '=================================================';
end $$;
