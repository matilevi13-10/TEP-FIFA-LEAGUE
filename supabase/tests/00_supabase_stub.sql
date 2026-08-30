-- Minimal stand-in for the Supabase-managed pieces the schema leans on.
create database tep;
\c tep
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text unique);
-- Real Supabase reads the JWT; here we read a session variable so tests can
-- impersonate any signed-in user.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid;
$$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
create publication supabase_realtime;
