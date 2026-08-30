-- ---------------------------------------------------------------------------
-- Retire the shared-PIN plumbing, now that Supabase Auth owns credentials
-- ---------------------------------------------------------------------------

drop table if exists public.team_secrets;
drop table if exists public.player_secrets;
alter table public.teams drop column if exists user_id;
alter table public.teams drop column if exists is_admin;

commit;

do $$
declare who text;
begin
  select admin_email into who from public.league_settings where id = 1;
  raise notice '=================================================';
  raise notice ' Migration complete.';
  raise notice ' Sign up with % to get the admin controls.', who;
  raise notice ' Keep "Confirm email" OFF in Supabase Auth.';
  raise notice '=================================================';
end $$;
