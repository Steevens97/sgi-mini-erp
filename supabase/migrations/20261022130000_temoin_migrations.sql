-- Outillage : témoin des migrations appliquées.
-- Permet de vérifier depuis l'extérieur (clé secrète uniquement) quelles migrations
-- l'intégration GitHub a réellement appliquées. Ne crée ni table ni colonne.

create or replace function public.migrations_appliquees()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select version::text from supabase_migrations.schema_migrations order by version;
$$;

revoke all on function public.migrations_appliquees() from public, anon, authenticated;
grant execute on function public.migrations_appliquees() to service_role;

-- Contrôles
do $$
declare
  v_nb integer;
  v_anon boolean;
begin
  select count(*) into v_nb from public.migrations_appliquees() as v where v = '20261022120000';
  if v_nb <> 1 then
    raise exception 'Témoin : la migration 20261022120000 (vérification du socle) n''est pas enregistrée';
  end if;

  select has_function_privilege('anon', 'public.migrations_appliquees()', 'execute') into v_anon;
  if v_anon then
    raise exception 'Témoin : la fonction migrations_appliquees() ne doit pas être accessible aux visiteurs';
  end if;
  select has_function_privilege('authenticated', 'public.migrations_appliquees()', 'execute') into v_anon;
  if v_anon then
    raise exception 'Témoin : la fonction migrations_appliquees() ne doit pas être accessible aux comptes connectés';
  end if;
end
$$;
