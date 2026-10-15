-- Infrastructure marker only; this migration does not create product tables.
create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;
create table app_private.schema_marker (
  id boolean primary key default true check (id),
  version integer not null check (version > 0)
);
insert into app_private.schema_marker (id, version) values (true, 1);
alter table app_private.schema_marker enable row level security;
revoke all on app_private.schema_marker from public, anon, authenticated;
-- Dedicated least-privilege runtime role. Password is configured outside source control.
create role app_health_reader nologin;
grant usage on schema app_private to app_health_reader;
grant select on app_private.schema_marker to app_health_reader;
create policy health_reader_select on app_private.schema_marker
  for select to app_health_reader using (true);

grant app_health_reader to postgres;
