-- Module 0 : vérification du socle existant.
-- Cette migration ne crée ni ne modifie rien : elle fait échouer le déploiement
-- si la base ne correspond pas à ce que l'application suppose.

do $$
declare
  v_tables_attendues text[] := array[
    'clients', 'prospects', 'devis', 'devis_lignes', 'collaborateurs', 'projets',
    'factures', 'temps', 'relances', 'conges', 'notes_de_frais', 'compteurs', 'profiles'
  ];
  v_table text;
  v_nb integer;
  v_texte text;
  v_public boolean;
begin
  -- 1. Les 13 tables existent
  foreach v_table in array v_tables_attendues loop
    select count(*) into v_nb
      from information_schema.tables
     where table_schema = 'public' and table_name = v_table;
    if v_nb <> 1 then
      raise exception 'Socle : la table public.% est introuvable', v_table;
    end if;
  end loop;

  -- 2. prochain_numero(p_cle text, p_prefixe text)
  select count(*) into v_nb
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'prochain_numero'
     and pg_get_function_identity_arguments(p.oid) = 'p_cle text, p_prefixe text';
  if v_nb <> 1 then
    select string_agg(pg_get_function_identity_arguments(p.oid), ' | ') into v_texte
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'prochain_numero';
    raise exception 'Socle : prochain_numero(p_cle text, p_prefixe text) introuvable (trouvé : %)',
      coalesce(v_texte, 'aucune');
  end if;

  -- 3. Bucket "justificatifs" privé
  select public into v_public from storage.buckets where id = 'justificatifs';
  if v_public is null then
    raise exception 'Socle : le bucket "justificatifs" est introuvable';
  end if;
  if v_public then
    raise exception 'Socle : le bucket "justificatifs" est PUBLIC, il doit être privé';
  end if;

  -- 4. Déclencheur de création des profils sur auth.users
  select count(*) into v_nb
    from pg_trigger
   where tgrelid = 'auth.users'::regclass and not tgisinternal;
  if v_nb < 1 then
    raise exception 'Socle : aucun déclencheur sur auth.users (création des profils)';
  end if;

  -- 5. collaborateurs.taux_horaire est NOT NULL
  select is_nullable into v_texte
    from information_schema.columns
   where table_schema = 'public' and table_name = 'collaborateurs' and column_name = 'taux_horaire';
  if v_texte is distinct from 'NO' then
    raise exception 'Socle : collaborateurs.taux_horaire devrait être NOT NULL (trouvé : %)',
      coalesce(v_texte, 'colonne absente');
  end if;

  -- 6. RLS activée sur les 13 tables
  foreach v_table in array v_tables_attendues loop
    select count(*) into v_nb
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_table and c.relrowsecurity;
    if v_nb <> 1 then
      raise exception 'Socle : la RLS n''est pas activée sur public.%', v_table;
    end if;
  end loop;
end
$$;
