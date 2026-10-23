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

-- Les 13 tables (colonnes, défauts et liens relevés sur l'API de Supabase le 23/10/2026)
create table public.clients (
  id uuid primary key default gen_random_uuid(), nom text not null, email_contact text,
  telephone text, adresse text, created_at timestamptz not null default now());
create table public.prospects (
  id uuid primary key default gen_random_uuid(), nom text not null, societe text, email text,
  telephone text, source text,
  statut text not null default 'contacte' check (statut in ('contacte','devis_envoye','gagne','perdu')),
  client_id uuid references public.clients(id), created_at timestamptz not null default now());
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
  id uuid primary key default gen_random_uuid(), nom text not null, prenom text, email text, poste text,
  date_entree date, manager_id uuid references public.collaborateurs(id),
  taux_horaire numeric not null default 0, solde_conges numeric not null default 25,
  created_at timestamptz not null default now());
create table public.projets (
  id uuid primary key default gen_random_uuid(), nom text not null, client_id uuid references public.clients(id),
  devis_id uuid references public.devis(id),
  statut text not null default 'en_cours' check (statut in ('en_cours','termine','annule')),
  created_at timestamptz not null default now());
create table public.factures (
  id uuid primary key default gen_random_uuid(), client_id uuid not null references public.clients(id),
  numero text, date_emission date not null default current_date, date_echeance date,
  periode_debut date, periode_fin date, total_ht numeric not null default 0, tva numeric not null default 0,
  total_ttc numeric not null default 0,
  statut text not null default 'brouillon' check (statut in ('brouillon','emise','envoyee','payee')),
  date_envoi timestamptz, created_at timestamptz not null default now());
create table public.temps (
  id uuid primary key default gen_random_uuid(), collaborateur_id uuid not null references public.collaborateurs(id),
  projet_id uuid not null references public.projets(id), date_saisie date not null default current_date,
  heures numeric not null, commentaire text,
  statut text not null default 'brouillon' check (statut in ('brouillon','soumis','valide')),
  facture_id uuid references public.factures(id), created_at timestamptz not null default now());
create table public.relances (
  id uuid primary key default gen_random_uuid(), facture_id uuid not null references public.factures(id),
  date_envoi timestamptz not null default now(), canal text not null default 'email', message text,
  created_at timestamptz not null default now());
create table public.conges (
  id uuid primary key default gen_random_uuid(), collaborateur_id uuid not null references public.collaborateurs(id),
  type text not null default 'conges_payes' check (type in ('conges_payes','rtt','sans_solde')),
  date_debut date not null, date_fin date not null, nb_jours numeric not null default 1, motif text,
  statut text not null default 'demandee' check (statut in ('demandee','validee','refusee')),
  valide_par uuid references public.collaborateurs(id), created_at timestamptz not null default now());
create table public.notes_de_frais (
  id uuid primary key default gen_random_uuid(), collaborateur_id uuid not null references public.collaborateurs(id),
  date_depense date not null default current_date, montant numeric not null default 0, categorie text,
  justificatif_url text,
  statut text not null default 'soumise' check (statut in ('soumise','validee','remboursee')),
  created_at timestamptz not null default now());
create table public.compteurs (cle text primary key, valeur integer not null default 0);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade, email text, nom text,
  role text not null default 'collaborateur' check (role in ('admin','manager','collaborateur')),
  collaborateur_id uuid references public.collaborateurs(id), created_at timestamptz not null default now());

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

-- Déclencheur de création des profils (le tout premier compte devient admin)
create function public.creer_profil() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, case when (select count(*) from public.profiles) = 0 then 'admin' else 'collaborateur' end);
  return new;
end $$;
create trigger creer_profil after insert on auth.users for each row execute function public.creer_profil();

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
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111','sgi@gmx.fr');
