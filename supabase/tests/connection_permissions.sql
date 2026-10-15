begin;
-- Run against a migrated local Supabase database.
set local role anon;
do $$ begin
  if has_schema_privilege(current_user, 'app_private', 'usage') then
    raise exception 'Anonymous schema access must be denied';
  end if;
  if has_table_privilege(current_user, (select oid from pg_class where relname = 'schema_marker' and relnamespace = (select oid from pg_namespace where nspname = 'app_private')), 'select') then
    raise exception 'Anonymous marker access must be denied';
  end if;
end $$;
reset role;
set local role authenticated;
do $$ begin
  if has_table_privilege(current_user, (select oid from pg_class where relname = 'schema_marker' and relnamespace = (select oid from pg_namespace where nspname = 'app_private')), 'select,insert,update,delete') then
    raise exception 'Authenticated marker access must be denied';
  end if;
end $$;
reset role;
set local role app_health_reader;
do $$ begin
  if (select version from app_private.schema_marker where id = true) <> 1 then
    raise exception 'Health reader must read marker';
  end if;
  if has_table_privilege(current_user, (select oid from pg_class where relname = 'schema_marker' and relnamespace = (select oid from pg_namespace where nspname = 'app_private')), 'insert,update,delete') then
    raise exception 'Health reader must not write';
  end if;
end $$;
rollback;

