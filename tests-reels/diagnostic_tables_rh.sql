-- Diagnostic en LECTURE SEULE (une seule instruction SELECT sur le catalogue PostgreSQL) :
-- ne crée, ne modifie, ne supprime rien. À exécuter dans Supabase → SQL Editor.
-- Tables profiles, conges, notes_de_frais, relances (fin de l'inventaire, nécessaire aux protections RH). Résultat : une ligne par élément.
with tables_cibles as (
  select c.oid, c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname in ('profiles', 'conges', 'notes_de_frais', 'relances')
),
declencheurs as (
  select t.oid, t.tgname, t.tgfoid, tc.relname, t.tgenabled
    from pg_trigger t join tables_cibles tc on tc.oid = t.tgrelid
   where not t.tgisinternal
),
fonctions as (
  -- fonctions appelées par ces déclencheurs, et toute fonction du schéma public qui touche à ces tables
  select distinct p.oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prokind = 'f'
     and (p.oid in (select tgfoid from declencheurs)
          or (n.nspname = 'public'
              and p.prosrc ~* '(conges|notes_de_frais|relances)' and p.proname <> 'prochain_numero'))
)
select '1. déclencheur' as rubrique,
       relname || '.' || tgname as objet,
       'actif=' || tgenabled::text || ' | fonction=' || tgfoid::regprocedure::text || E'\n' || pg_get_triggerdef(oid) as detail
  from declencheurs
union all
select '2. fonction', p.oid::regprocedure::text,
       'security definer=' || p.prosecdef || E'\n' || pg_get_functiondef(p.oid)
  from fonctions f join pg_proc p on p.oid = f.oid
union all
select '3. colonne', tc.relname || '.' || a.attname,
       format_type(a.atttypid, a.atttypmod)
       || ' | not null=' || a.attnotnull
       || ' | défaut=' || coalesce(case when a.attgenerated::text = '' then pg_get_expr(d.adbin, d.adrelid) end, '—')
       || ' | calculée=' || coalesce(case when a.attgenerated::text <> '' then pg_get_expr(d.adbin, d.adrelid) end, 'non')
       || ' | identité=' || coalesce(nullif(a.attidentity::text, ''), 'non')
  from tables_cibles tc
  join pg_attribute a on a.attrelid = tc.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
union all
select '4. contrainte', tc.relname || '.' || co.conname, co.contype::text || ' | ' || pg_get_constraintdef(co.oid)
  from tables_cibles tc join pg_constraint co on co.conrelid = tc.oid
union all
select '5. règle (rule)', r.tablename || '.' || r.rulename, r.definition
  from pg_rules r where r.schemaname = 'public' and r.tablename in ('profiles', 'conges', 'notes_de_frais', 'relances')
order by 1, 2;
