-- Base d'ESSAI locale (jamais Supabase) : reconstitution simplifiée du socle pour rejouer
-- les migrations et tester les déclencheurs. Les éléments Supabase (auth, storage, rôles)
-- sont des imitations minimales ; prochain_numero est la copie exacte de la définition réelle.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_auth_admin nologin;
grant anon, authenticated, service_role to postgres;

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_app_meta_data jsonb not null default '{}'::jsonb,
  banned_until timestamptz
);
create table auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  not_after timestamptz
);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;

create schema storage;
create table storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text, metadata jsonb, created_at timestamptz default now()
);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
insert into storage.buckets (id, name, public) values ('justificatifs', 'justificatifs', false);
create policy "provisoire_stockage" on storage.objects for all to authenticated using (true) with check (true);

create schema supabase_migrations;
create table supabase_migrations.schema_migrations (version text primary key);

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- Les 13 tables. Définitions EXACTES relevées dans Supabase le 23/10/2026 (tests-reels/diagnostic_*.sql,
-- exécutés par l'utilisateur) pour clients, prospects, devis, devis_lignes, collaborateurs, projets,
-- factures, temps, compteurs : types et précisions, défauts, noms de contraintes, comportements ON DELETE.
-- relances, conges, notes_de_frais, profiles : relevés le 23/10/2026 (tests-reels/diagnostic_tables_rh.sql).
-- Les 13 tables sont désormais alignées sur Supabase.
create table public.clients (
  id uuid not null default gen_random_uuid(), nom text not null, email_contact text,
  telephone text, adresse text, created_at timestamptz not null default now(),
  constraint clients_pkey primary key (id));
create table public.prospects (
  id uuid not null default gen_random_uuid(), nom text not null, societe text, email text,
  telephone text, source text, statut text not null default 'contacte',
  client_id uuid, created_at timestamptz not null default now(),
  constraint prospects_pkey primary key (id),
  constraint prospects_client_id_fkey foreign key (client_id) references public.clients(id) on delete set null,
  constraint prospects_statut_check check (statut = any (array['contacte'::text, 'devis_envoye'::text, 'gagne'::text, 'perdu'::text])));
-- devis et devis_lignes : définitions EXACTES relevées dans Supabase le 23/10/2026
-- (tests-reels/diagnostic_totaux_devis.sql) : précisions numeric(12,2)/(10,2), UNIQUE (numero), cascades.
create table public.devis (
  id uuid not null default gen_random_uuid(), prospect_id uuid not null,
  numero text, date_emission date not null default current_date,
  statut text not null default 'brouillon',
  total_ht numeric(12,2) not null default 0, tva numeric(12,2) not null default 0, total_ttc numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  constraint devis_pkey primary key (id),
  constraint devis_numero_key unique (numero),
  constraint devis_prospect_id_fkey foreign key (prospect_id) references public.prospects(id) on delete cascade,
  constraint devis_statut_check check (statut = any (array['brouillon'::text, 'envoye'::text, 'accepte'::text, 'refuse'::text])));
create table public.devis_lignes (
  id uuid not null default gen_random_uuid(), devis_id uuid not null,
  designation text not null, quantite numeric(10,2) not null default 1, prix_unitaire numeric(12,2) not null default 0,
  montant_ht numeric(12,2) not null default 0, created_at timestamptz not null default now(),
  constraint devis_lignes_pkey primary key (id),
  constraint devis_lignes_devis_id_fkey foreign key (devis_id) references public.devis(id) on delete cascade);
create table public.collaborateurs (
  id uuid not null default gen_random_uuid(), nom text not null, prenom text, email text, poste text,
  date_entree date, manager_id uuid,
  taux_horaire numeric(10,2) not null default 0, solde_conges numeric(6,2) not null default 25,
  created_at timestamptz not null default now(),
  constraint collaborateurs_pkey primary key (id),
  constraint collaborateurs_manager_id_fkey foreign key (manager_id) references public.collaborateurs(id) on delete set null);
create table public.projets (
  id uuid not null default gen_random_uuid(), nom text not null, client_id uuid, devis_id uuid,
  statut text not null default 'en_cours', created_at timestamptz not null default now(),
  constraint projets_pkey primary key (id),
  constraint projets_client_id_fkey foreign key (client_id) references public.clients(id) on delete set null,
  constraint projets_devis_id_fkey foreign key (devis_id) references public.devis(id) on delete set null,
  constraint projets_statut_check check (statut = any (array['en_cours'::text, 'termine'::text, 'annule'::text])));
create table public.factures (
  id uuid not null default gen_random_uuid(), client_id uuid not null,
  numero text, date_emission date not null default current_date, date_echeance date,
  periode_debut date, periode_fin date, total_ht numeric(12,2) not null default 0, tva numeric(12,2) not null default 0,
  total_ttc numeric(12,2) not null default 0, statut text not null default 'brouillon',
  date_envoi timestamptz, created_at timestamptz not null default now(),
  constraint factures_pkey primary key (id),
  constraint factures_numero_key unique (numero),
  constraint factures_client_id_fkey foreign key (client_id) references public.clients(id) on delete restrict,
  constraint factures_statut_check check (statut = any (array['brouillon'::text, 'emise'::text, 'envoyee'::text, 'payee'::text])));
create table public.temps (
  id uuid not null default gen_random_uuid(), collaborateur_id uuid not null,
  projet_id uuid not null, date_saisie date not null default current_date,
  heures numeric(5,2) not null, commentaire text, statut text not null default 'brouillon',
  facture_id uuid, created_at timestamptz not null default now(),
  constraint temps_pkey primary key (id),
  constraint temps_collaborateur_id_fkey foreign key (collaborateur_id) references public.collaborateurs(id) on delete cascade,
  constraint temps_projet_id_fkey foreign key (projet_id) references public.projets(id) on delete cascade,
  constraint temps_facture_id_fkey foreign key (facture_id) references public.factures(id) on delete set null,
  constraint temps_statut_check check (statut = any (array['brouillon'::text, 'soumis'::text, 'valide'::text])));
create table public.relances (
  id uuid not null default gen_random_uuid(), facture_id uuid not null,
  date_envoi timestamptz not null default now(), canal text not null default 'email', message text,
  created_at timestamptz not null default now(),
  constraint relances_pkey primary key (id),
  constraint relances_facture_id_fkey foreign key (facture_id) references public.factures(id) on delete cascade);
create table public.conges (
  id uuid not null default gen_random_uuid(), collaborateur_id uuid not null,
  type text not null default 'conges_payes', date_debut date not null, date_fin date not null,
  nb_jours numeric(5,2) not null default 1, motif text, statut text not null default 'demandee',
  valide_par uuid, created_at timestamptz not null default now(),
  constraint conges_pkey primary key (id),
  constraint conges_collaborateur_id_fkey foreign key (collaborateur_id) references public.collaborateurs(id) on delete cascade,
  constraint conges_valide_par_fkey foreign key (valide_par) references public.collaborateurs(id) on delete set null,
  constraint conges_statut_check check (statut = any (array['demandee'::text, 'validee'::text, 'refusee'::text])),
  constraint conges_type_check check (type = any (array['conges_payes'::text, 'rtt'::text, 'sans_solde'::text])));
create table public.notes_de_frais (
  id uuid not null default gen_random_uuid(), collaborateur_id uuid not null,
  date_depense date not null default current_date, montant numeric(10,2) not null default 0, categorie text,
  justificatif_url text, statut text not null default 'soumise', created_at timestamptz not null default now(),
  constraint notes_de_frais_pkey primary key (id),
  constraint notes_de_frais_collaborateur_id_fkey foreign key (collaborateur_id) references public.collaborateurs(id) on delete cascade,
  constraint notes_de_frais_statut_check check (statut = any (array['soumise'::text, 'validee'::text, 'remboursee'::text])));
create table public.compteurs (cle text not null, valeur integer not null default 0,
  constraint compteurs_pkey primary key (cle));
create table public.profiles (
  id uuid not null, email text, nom text, role text not null default 'collaborateur',
  collaborateur_id uuid, created_at timestamptz not null default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_id_fkey foreign key (id) references auth.users(id) on delete cascade,
  constraint profiles_collaborateur_id_fkey foreign key (collaborateur_id) references public.collaborateurs(id) on delete set null,
  constraint profiles_role_check check (role = any (array['admin'::text, 'manager'::text, 'collaborateur'::text])));

do $$
declare t text;
begin
  foreach t in array array['clients','prospects','devis','devis_lignes','collaborateurs','projets','factures',
                           'temps','relances','conges','notes_de_frais','compteurs','profiles'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "provisoire" on public.%I for all to authenticated using (true) with check (true)', t);
    execute format('grant all on public.%I to anon, authenticated, service_role', t);
  end loop;
end $$;

-- prochain_numero : copie EXACTE de la définition réelle (transmise par l'utilisateur le 23/10/2026)
CREATE OR REPLACE FUNCTION public.prochain_numero(p_cle text, p_prefixe text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
declare
  v_annee  text := to_char(current_date, 'YYYY');
  v_cle    text := p_cle || '_' || v_annee;
  v_valeur integer;
begin
  insert into compteurs (cle, valeur) values (v_cle, 0)
  on conflict (cle) do nothing;

  update compteurs
     set valeur = valeur + 1
   where cle = v_cle
  returning valeur into v_valeur;

  return p_prefixe || '-' || v_annee || '-' || lpad(v_valeur::text, 4, '0');
end;
$function$;

-- Déclencheur de création des profils : fonction réelle creer_profil_a_inscription (relevée le 23/10/2026).
-- Le nom du déclencheur sur auth.users n'a pas été relevé (sans incidence sur les migrations).
CREATE OR REPLACE FUNCTION public.creer_profil_a_inscription()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text;
begin
  -- Le TOUT PREMIER compte cree devient administrateur.
  -- Tous les suivants sont crees comme collaborateurs.
  if not exists (select 1 from public.profiles) then
    v_role := 'admin';
  else
    v_role := 'collaborateur';
  end if;

  insert into public.profiles (id, email, role)
  values (new.id, new.email, v_role)
  on conflict (id) do nothing;

  return new;
end;
$function$;
create trigger creer_profil_a_inscription after insert on auth.users for each row execute function public.creer_profil_a_inscription();

-- Données de démonstration minimales (comme le jeu réel : 2 clients, 2 prospects, 2 projets…)
insert into public.collaborateurs (id, nom, prenom, email, poste, taux_horaire) values
  ('22222222-2222-2222-2222-222222222222','Dubois','Bruno','bruno@exemple.fr','Manager',120),
  ('22222222-2222-2222-2222-222222222221','Moreau','Lea','lea@exemple.fr','Consultante senior',95),
  ('22222222-2222-2222-2222-222222222223','Nguyen','Chloe','chloe@exemple.fr','Consultante',75);
insert into public.clients (id, nom) values
  ('33333333-3333-3333-3333-333333333331','Client démo 1'), ('33333333-3333-3333-3333-333333333332','Client démo 2');
insert into public.prospects (nom, societe, statut) values ('Prospect démo 1','Société A','contacte'),
  ('Prospect démo 2','Société B','gagne');
insert into public.projets (nom, client_id) values ('Projet démo 1','33333333-3333-3333-3333-333333333331'),
  ('Projet démo 2','33333333-3333-3333-3333-333333333332');
-- Comme en production (relevé du 23/10/2026) : Moreau et Nguyen ont un manager (Dubois) ; 3 temps de
-- démonstration (2 validés, 1 soumis), sans auteur ni validation connus.
update public.collaborateurs set manager_id = '22222222-2222-2222-2222-222222222222'
 where id in ('22222222-2222-2222-2222-222222222221', '22222222-2222-2222-2222-222222222223');
insert into public.temps (collaborateur_id, projet_id, date_saisie, heures, statut)
-- Dates des temps de démonstration : date de Martinique (comme l'application), pas current_date (UTC).
select '22222222-2222-2222-2222-222222222221'::uuid, id, (now() at time zone 'America/Martinique')::date - 5, 6.5, 'valide' from public.projets where nom = 'Projet démo 1'
union all select '22222222-2222-2222-2222-222222222221', id, (now() at time zone 'America/Martinique')::date - 4, 7, 'valide' from public.projets where nom = 'Projet démo 1'
union all select '22222222-2222-2222-2222-222222222223', id, (now() at time zone 'America/Martinique')::date - 3, 4, 'soumis' from public.projets where nom = 'Projet démo 2';
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','sgi@gmx.fr');
