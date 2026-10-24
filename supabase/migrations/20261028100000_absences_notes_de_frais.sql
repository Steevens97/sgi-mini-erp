-- Module Absences et notes de frais (1re version). Décisions de l'utilisateur du 24/10/2026 (voir CLAUDE.md) :
--   - congés : nombre de jours saisi (pas de calendrier des jours fériés), demi-journées, pas de 0,5 ; congés payés
--     prélevés sur solde_conges et RTT sur solde_rtt UNE fois, à la validation, jamais au-delà du solde ; sans solde :
--     aucun prélèvement ; ajustements des soldes par l'administrateur, motivés et tracés ;
--   - personne ne décide de ses propres congés ni de ses propres notes de frais (l'administrateur compris) ;
--   - un congé validé ne devient jamais « refusée » et ne s'annule pas dans cette version ;
--   - demandes rétroactives : administrateur seulement, avec motif ; chevauchements refusés à la demi-journée
--     près (demandes en cours et validées ; une demande refusée ne bloque rien) ; aucune absence après la sortie ;
--   - notes de frais : montant TTC seul, catégories fixes (« autre » = précision obligatoire), justificatif PDF,
--     JPEG ou PNG de 10 Mo au plus, déposé et consulté uniquement par le serveur ; une note validée, refusée ou
--     remboursée ne change plus de contenu ni de justificatif ; remboursement DÉCLARÉ par l'administrateur,
--     correction motivée avec historique ;
--   - historiques écrits par la base seulement, en ajout seul ; aucune relance automatique.
-- Soldes existants : congés payés INCHANGÉS ; RTT initialisés à 0 avec la mention « droits non renseignés ».
-- Confidentialité : soldes lisibles seulement via la vue absences_soldes (soi, équipe directe du manager, admin) ;
-- la lecture de solde_conges par tous les managers (ouverte jusqu'ici) est fermée.
-- Compatible avec le site en ligne : aucune colonne existante n'est supprimée ; le site actuel ne lit ni les soldes
-- ni les congés ni les notes de frais, et n'écrit dans les fiches que des colonnes qui restent permises.

-- 0. Préalables -----------------------------------------------------------------------------------------------
do $$
declare
  v_nb integer;
begin
  select count(*) into v_nb from supabase_migrations.schema_migrations
   where version in ('20261025100000', '20261026100000', '20261027100000');
  if v_nb <> 3 then
    raise exception 'Absences : les migrations RH (20261025100000, 20261026100000) et Finance (20261027100000) doivent être appliquées avant';
  end if;
  select count(*) into v_nb from public.conges;
  if v_nb > 0 then
    raise exception 'Absences : % congé(s) existent déjà ; examen nécessaire avant de poser les règles', v_nb;
  end if;
  select count(*) into v_nb from public.notes_de_frais;
  if v_nb > 0 then
    raise exception 'Absences : % note(s) de frais existent déjà ; examen nécessaire avant de poser les règles', v_nb;
  end if;
  select count(*) into v_nb from storage.objects where bucket_id = 'justificatifs';
  if v_nb > 0 then
    raise exception 'Absences : % fichier(s) déjà présents dans le bucket justificatifs ; examen nécessaire (le nettoyage des dépôts abandonnés pourrait les viser)', v_nb;
  end if;
  if not exists (select 1 from storage.buckets where id = 'justificatifs' and not public) then
    raise exception 'Absences : bucket privé « justificatifs » absent ou public';
  end if;
  select count(*) into v_nb from public.collaborateurs where solde_conges < 0;
  if v_nb > 0 then
    raise exception 'Absences : % fiche(s) ont un solde de congés négatif ; examen nécessaire', v_nb;
  end if;
end
$$;

-- 1. Colonnes (approuvées par l'utilisateur le 24/10/2026) ---------------------------------------------------------
alter table public.collaborateurs
  add column if not exists solde_rtt numeric(6, 2) not null default 0,
  add column if not exists historique_soldes jsonb not null default '[]'::jsonb;

alter table public.conges
  add column if not exists debut_apres_midi boolean not null default false,  -- l'absence commence l'après-midi
  add column if not exists fin_midi boolean not null default false,          -- l'absence finit à midi
  add column if not exists demande_par uuid,             -- compte auteur de la demande (sans lien : un compte révoqué est supprimé)
  add column if not exists demande_par_nom text,
  add column if not exists demande_le timestamptz,
  add column if not exists motif_retroactif text,        -- obligatoire pour une demande sur une date passée (admin)
  add column if not exists decide_par uuid,              -- compte auteur de la décision
  add column if not exists decide_par_nom text,
  add column if not exists decide_le timestamptz,
  add column if not exists motif_decision text,          -- obligatoire pour un refus
  add column if not exists solde_preleve numeric(5, 2),  -- jours prélevés à la validation (0 pour un congé sans solde)
  add column if not exists historique jsonb not null default '[]'::jsonb,
  add column if not exists essai boolean not null default false;

alter table public.notes_de_frais
  add column if not exists objet text,
  add column if not exists categorie_precision text,
  add column if not exists justificatif_empreinte text,  -- SHA-256 calculé par le serveur sur le fichier stocké
  add column if not exists justificatif_taille bigint,
  add column if not exists justificatif_type text,
  add column if not exists justificatif_depose_le timestamptz,
  add column if not exists soumise_par uuid,
  add column if not exists soumise_par_nom text,
  add column if not exists soumise_le timestamptz,
  add column if not exists decide_par uuid,
  add column if not exists decide_par_nom text,
  add column if not exists decide_le timestamptz,
  add column if not exists motif_decision text,
  add column if not exists rembourse_le date,
  add column if not exists reference_remboursement text,
  add column if not exists rembourse_declare_par uuid,
  add column if not exists rembourse_declare_par_nom text,
  add column if not exists rembourse_declare_le timestamptz,
  add column if not exists historique jsonb not null default '[]'::jsonb,
  add column if not exists essai boolean not null default false;

-- 2. Soldes existants : congés payés inchangés, RTT à 0 « droits non renseignés ». Fait AVANT la pose du
--    déclencheur qui interdit toute écriture directe de l'historique des soldes.
update public.collaborateurs
   set historique_soldes = jsonb_build_array(
         jsonb_build_object('type', 'conges_payes', 'action', 'initial', 'le', now(), 'avant', null, 'apres', solde_conges,
           'auteur', null, 'auteur_nom', null,
           'motif', 'Solde existant avant le module Absences (migration 20261028100000), repris sans modification.'),
         jsonb_build_object('type', 'rtt', 'action', 'initial', 'le', now(), 'avant', null, 'apres', 0,
           'auteur', null, 'auteur_nom', null,
           'motif', 'Droits RTT non renseignés : aucune acquisition automatique ; à renseigner par un ajustement motivé.'))
 where historique_soldes = '[]'::jsonb;

-- 3. Contraintes -----------------------------------------------------------------------------------------------
alter table public.collaborateurs drop constraint if exists collaborateurs_soldes_positifs;
alter table public.collaborateurs add constraint collaborateurs_soldes_positifs check (solde_conges >= 0 and solde_rtt >= 0);
alter table public.collaborateurs drop constraint if exists collaborateurs_historique_soldes_liste;
alter table public.collaborateurs add constraint collaborateurs_historique_soldes_liste
  check (jsonb_typeof(historique_soldes) = 'array');

-- Demi-journées : la période couvre (fin - début) × 2 + 2 demi-journées, moins l'après-midi de départ et la fin à midi.
alter table public.conges drop constraint if exists conges_periode_coherente;
alter table public.conges add constraint conges_periode_coherente
  check (date_fin >= date_debut
         and (date_fin - date_debut) * 2 + 2 - debut_apres_midi::integer - fin_midi::integer > 0);
alter table public.conges drop constraint if exists conges_nb_jours_demi_journees;
alter table public.conges add constraint conges_nb_jours_demi_journees
  check (nb_jours > 0 and nb_jours * 2 = trunc(nb_jours * 2)
         and nb_jours * 2 <= (date_fin - date_debut) * 2 + 2 - debut_apres_midi::integer - fin_midi::integer);
alter table public.conges drop constraint if exists conges_solde_preleve_positif;
alter table public.conges add constraint conges_solde_preleve_positif check (solde_preleve is null or solde_preleve >= 0);
alter table public.conges drop constraint if exists conges_historique_liste;
alter table public.conges add constraint conges_historique_liste check (jsonb_typeof(historique) = 'array');

alter table public.notes_de_frais drop constraint if exists notes_de_frais_statut_check;
alter table public.notes_de_frais add constraint notes_de_frais_statut_check
  check (statut = any (array['soumise'::text, 'validee'::text, 'refusee'::text, 'remboursee'::text]));
alter table public.notes_de_frais drop constraint if exists notes_de_frais_categorie_prevue;
alter table public.notes_de_frais add constraint notes_de_frais_categorie_prevue
  check (categorie is not null
         and categorie in ('deplacement', 'repas', 'hebergement', 'carburant', 'fournitures', 'autre')
         and (categorie <> 'autre' or coalesce(btrim(categorie_precision), '') <> ''));
alter table public.notes_de_frais drop constraint if exists notes_de_frais_objet_renseigne;
alter table public.notes_de_frais add constraint notes_de_frais_objet_renseigne
  check (objet is not null and objet = btrim(objet) and length(objet) between 1 and 300);
alter table public.notes_de_frais drop constraint if exists notes_de_frais_montant_positif;
alter table public.notes_de_frais add constraint notes_de_frais_montant_positif check (montant > 0);
alter table public.notes_de_frais drop constraint if exists notes_de_frais_justificatif_conforme;
alter table public.notes_de_frais add constraint notes_de_frais_justificatif_conforme
  check (justificatif_url is not null
         and justificatif_type in ('application/pdf', 'image/jpeg', 'image/png')
         and justificatif_taille between 1 and 10485760
         and justificatif_empreinte ~ '^[0-9a-f]{64}$');
alter table public.notes_de_frais drop constraint if exists notes_de_frais_historique_liste;
alter table public.notes_de_frais add constraint notes_de_frais_historique_liste check (jsonb_typeof(historique) = 'array');
-- Un fichier n'est rattaché qu'à une seule note.
create unique index if not exists notes_de_frais_justificatif_unique on public.notes_de_frais (justificatif_url);

-- 4. Outils internes ---------------------------------------------------------------------------------------------
-- Contexte posé par les fonctions de service (local à la transaction, inaccessible aux jetons) :
--   sgi.abs_auteur (compte vérifié), sgi.abs_operation (intention), sgi.abs_motif (motif saisi),
--   sgi.abs_evenement (événement de solde à inscrire, consommé par le déclencheur des fiches).
create or replace function public.abs_contexte(p_auteur uuid, p_operation text, p_motif text)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.verifier_auteur_rh(p_auteur);   -- compte actif (non banni, mot de passe définitif)
  perform set_config('sgi.abs_auteur', p_auteur::text, true);
  perform set_config('sgi.abs_operation', coalesce(p_operation, ''), true);
  perform set_config('sgi.abs_motif', coalesce(p_motif, ''), true);
  perform set_config('sgi.abs_evenement', '', true);
  return v_role;
end
$$;

create or replace function public.abs_fin_contexte()
returns void
language sql
as $$
  select set_config('sgi.abs_auteur', '', true), set_config('sgi.abs_operation', '', true),
         set_config('sgi.abs_motif', '', true), set_config('sgi.abs_evenement', '', true);
$$;

create or replace function public.abs_auteur_courant(out o_id uuid, out o_role text, out o_collaborateur uuid, out o_nom text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  o_id := nullif(current_setting('sgi.abs_auteur', true), '')::uuid;
  if o_id is null then
    raise exception 'Absences : auteur non identifié ; passez par l''application.';
  end if;
  select role, collaborateur_id, coalesce(nullif(nom, ''), email) into o_role, o_collaborateur, o_nom
    from public.profiles where id = o_id;
  if o_role is null then
    raise exception 'Absences : auteur inconnu.';
  end if;
end
$$;

-- Demi-journées numérotées (2 par jour) : début inclus, fin exclue. Deux périodes se chevauchent si
-- début A < fin B et début B < fin A.
create or replace function public.abs_demi_debut(p_date date, p_apres_midi boolean)
returns integer
language sql
immutable
as $$
  select (p_date - date '2000-01-01') * 2 + case when p_apres_midi then 1 else 0 end;
$$;

create or replace function public.abs_demi_fin(p_date date, p_fin_midi boolean)
returns integer
language sql
immutable
as $$
  select (p_date - date '2000-01-01') * 2 + 2 - case when p_fin_midi then 1 else 0 end;
$$;

-- Fiche d'essai : adresse du domaine réservé « exemple.invalid » (RFC 6761 : jamais une adresse réelle).
-- Les congés et notes de frais de ces fiches sont marqués « essai » par la base et seuls supprimables.
create or replace function public.abs_fiche_essai(p_email text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(p_email), '') like '%@exemple.invalid';
$$;

-- Justificatif : contrôles faits par la BASE (le contenu du fichier, lui, est contrôlé par le serveur :
-- signature du format et SHA-256 ; la base ne lit pas les octets du fichier).
create or replace function public.abs_controler_justificatif(p_collaborateur uuid, p_note uuid, p_chemin text,
  p_type text, p_taille bigint, p_empreinte text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cree timestamptz;
  v_meta jsonb;
begin
  if p_chemin is null then
    raise exception 'Justificatif obligatoire : déposez un fichier PDF, JPEG ou PNG.';
  end if;
  if p_chemin !~ ('^' || p_collaborateur::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png)$') then
    raise exception 'Justificatif : emplacement non conforme (dossier du collaborateur concerné uniquement).';
  end if;
  if p_type is null or p_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'Justificatif : format refusé (PDF, JPEG ou PNG uniquement).';
  end if;
  if (p_type = 'application/pdf' and p_chemin !~ '\.pdf$') or (p_type = 'image/jpeg' and p_chemin !~ '\.jpg$')
     or (p_type = 'image/png' and p_chemin !~ '\.png$') then
    raise exception 'Justificatif : extension et format incohérents.';
  end if;
  if p_taille is null or p_taille < 1 or p_taille > 10485760 then
    raise exception 'Justificatif : fichier vide ou de plus de 10 Mo.';
  end if;
  if p_empreinte is null or p_empreinte !~ '^[0-9a-f]{64}$' then
    raise exception 'Justificatif : empreinte SHA-256 absente ou mal formée.';
  end if;
  select o.created_at, o.metadata into v_cree, v_meta
    from storage.objects o where o.bucket_id = 'justificatifs' and o.name = p_chemin;
  if v_cree is null then
    raise exception 'Justificatif absent du stockage : déposez le fichier à nouveau.';
  end if;
  if (v_meta ->> 'size')::bigint is distinct from p_taille then
    raise exception 'Justificatif : la taille stockée diffère de la taille contrôlée par le serveur.';
  end if;
  if v_meta ->> 'mimetype' is distinct from p_type then
    raise exception 'Justificatif : le type stocké diffère du type contrôlé par le serveur.';
  end if;
  -- Un dépôt se rattache dans les 30 minutes ; le nettoyage ne vise que les dépôts de plus d'une heure : un fichier
  -- en cours de rattachement n'est jamais supprimé par le nettoyage.
  if v_cree < now() - interval '30 minutes' then
    raise exception 'Justificatif déposé il y a plus de 30 minutes : déposez le fichier à nouveau.';
  end if;
  if exists (select 1 from public.notes_de_frais n
              where n.id is distinct from p_note
                and (n.justificatif_url = p_chemin or strpos(n.historique::text, p_chemin) > 0)) then
    raise exception 'Justificatif déjà rattaché à une autre note de frais.';
  end if;
end
$$;

-- Contenu d'une note : contrôles communs à la création et à la modification.
create or replace function public.abs_controler_contenu_note(p_collaborateur uuid, p_date date, p_categorie text,
  p_precision text, p_objet text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_entree date;
  v_sortie date;
begin
  select date_entree, date_sortie into v_entree, v_sortie from public.collaborateurs where id = p_collaborateur;
  if not found then
    raise exception 'Fiche collaborateur introuvable.';
  end if;
  if p_date is null then
    raise exception 'Date de la dépense obligatoire.';
  end if;
  if p_date > (now() at time zone 'America/Martinique')::date then
    raise exception 'Date de la dépense refusée : elle ne peut pas être dans le futur.';
  end if;
  if v_entree is not null and p_date < v_entree then
    raise exception 'Date de la dépense refusée : antérieure à l''entrée du collaborateur (%).', to_char(v_entree, 'DD/MM/YYYY');
  end if;
  if v_sortie is not null and p_date > v_sortie then
    raise exception 'Date de la dépense refusée : postérieure à la sortie du collaborateur (%).', to_char(v_sortie, 'DD/MM/YYYY');
  end if;
  if p_categorie is null or p_categorie not in ('deplacement', 'repas', 'hebergement', 'carburant', 'fournitures', 'autre') then
    raise exception 'Catégorie inconnue : déplacement, repas, hébergement, carburant, fournitures ou autre.';
  end if;
  if p_categorie = 'autre' and coalesce(btrim(p_precision), '') = '' then
    raise exception 'Catégorie « autre » : la précision est obligatoire.';
  end if;
  if coalesce(btrim(p_objet), '') = '' then
    raise exception 'L''objet de la dépense est obligatoire.';
  end if;
  if length(btrim(p_objet)) > 300 then
    raise exception 'L''objet de la dépense est limité à 300 caractères.';
  end if;
end
$$;

-- 5. Déclencheurs ------------------------------------------------------------------------------------------------
-- 5a. Fiches : soldes modifiés uniquement par un ajustement motivé ou un prélèvement de validation ; historique des
--     soldes en ajout seul ; date de sortie compatible avec les absences ; essais et réel jamais mélangés.
create or replace function public.collaborateurs_absences_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := nullif(current_setting('sgi.abs_operation', true), '');
  v_evt jsonb := nullif(current_setting('sgi.abs_evenement', true), '')::jsonb;
  v_fin date;
begin
  if tg_op = 'INSERT' then
    if new.solde_rtt <> 0 then
      raise exception 'Une nouvelle fiche démarre avec un solde RTT à 0 (droits non renseignés) ; renseignez-le ensuite par un ajustement motivé.';
    end if;
    if new.historique_soldes is distinct from '[]'::jsonb then
      raise exception 'Historique des soldes : alimenté par la base seulement.';
    end if;
    new.historique_soldes := jsonb_build_array(
      jsonb_build_object('type', 'conges_payes', 'action', 'initial', 'le', now(), 'avant', null, 'apres', new.solde_conges,
        'auteur', null, 'auteur_nom', null, 'motif', 'Solde à la création de la fiche.'),
      jsonb_build_object('type', 'rtt', 'action', 'initial', 'le', now(), 'avant', null, 'apres', 0,
        'auteur', null, 'auteur_nom', null,
        'motif', 'Droits RTT non renseignés : aucune acquisition automatique ; à renseigner par un ajustement motivé.'));
    return new;
  end if;

  if new.historique_soldes is distinct from old.historique_soldes then
    raise exception 'Historique des soldes : alimenté par la base seulement, ni modifiable ni effaçable.';
  end if;
  if v_op in ('ajustement', 'prelevement') and v_evt is not null then
    if (v_evt ->> 'type' = 'conges_payes' and new.solde_rtt is distinct from old.solde_rtt)
       or (v_evt ->> 'type' = 'rtt' and new.solde_conges is distinct from old.solde_conges)
       or v_evt ->> 'type' not in ('conges_payes', 'rtt') then
      raise exception 'Soldes : un seul solde change par opération, celui de l''événement.';
    end if;
    new.historique_soldes := old.historique_soldes || jsonb_build_array(v_evt || jsonb_build_object('le', now(),
      'avant', case v_evt ->> 'type' when 'rtt' then old.solde_rtt else old.solde_conges end,
      'apres', case v_evt ->> 'type' when 'rtt' then new.solde_rtt else new.solde_conges end));
    perform set_config('sgi.abs_evenement', '', true);   -- consommé : un seul événement par opération
  elsif (new.solde_conges, new.solde_rtt) is distinct from (old.solde_conges, old.solde_rtt) then
    raise exception 'Soldes de congés : modification directe interdite ; utilisez un ajustement motivé (administrateur).';
  end if;

  if new.date_sortie is not null and new.date_sortie is distinct from old.date_sortie then
    select max(date_fin) into v_fin from public.conges where collaborateur_id = new.id and statut in ('demandee', 'validee');
    if v_fin is not null and v_fin > new.date_sortie then
      raise exception 'Date de sortie refusée : une absence (demandée ou validée) court jusqu''au %.', to_char(v_fin, 'DD/MM/YYYY');
    end if;
  end if;
  if public.abs_fiche_essai(new.email) <> public.abs_fiche_essai(old.email)
     and (exists (select 1 from public.conges where collaborateur_id = new.id)
          or exists (select 1 from public.notes_de_frais where collaborateur_id = new.id)) then
    raise exception 'Email refusé : passer d''une adresse d''essai (@exemple.invalid) à une adresse réelle, ou l''inverse, est impossible quand la fiche porte des absences ou des notes de frais.';
  end if;
  return new;
end
$$;
drop trigger if exists collaborateurs_absences_controle on public.collaborateurs;
create trigger collaborateurs_absences_controle before insert or update on public.collaborateurs
  for each row execute function public.collaborateurs_absences_controle();

-- 5b. Congés : toutes les règles, quel que soit le chemin d'écriture.
create or replace function public.conges_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := nullif(current_setting('sgi.abs_operation', true), '');
  v_motif text := nullif(btrim(coalesce(current_setting('sgi.abs_motif', true), '')), '');
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  a record;
  v_email text;
  v_entree date;
  v_sortie date;
  v_cp numeric;
  v_rtt numeric;
  v_rtt_renseigne boolean;
  v_max numeric;
  v_conflit record;
  v_preleve numeric;
  v_evt jsonb;
begin
  if tg_op = 'DELETE' then
    if v_op = 'nettoyage_essais' and old.essai then
      return old;
    end if;
    raise exception 'Une demande de congé ne se supprime pas (historique conservé).';
  end if;
  if v_op is null then
    raise exception 'Congés : écriture directe interdite ; passez par l''application.';
  end if;
  select * into a from public.abs_auteur_courant();

  -- Demande -------------------------------------------------------------------------------------------------------
  if tg_op = 'INSERT' then
    if v_op <> 'demander_conge' then
      raise exception 'Congés : une demande se crée par l''application seulement.';
    end if;
    if new.statut <> 'demandee' or new.valide_par is not null or new.decide_par is not null or new.decide_par_nom is not null
       or new.decide_le is not null or new.motif_decision is not null or new.solde_preleve is not null
       or new.historique is distinct from '[]'::jsonb then
      raise exception 'Une demande de congé naît « demandée », sans décision ni historique.';
    end if;
    -- Verrou de la fiche : deux demandes simultanées de la même personne sont examinées l'une après l'autre.
    select email, date_entree, date_sortie into v_email, v_entree, v_sortie
      from public.collaborateurs where id = new.collaborateur_id for update;
    if not found then
      raise exception 'Fiche collaborateur introuvable.';
    end if;
    if a.o_role <> 'admin' then
      if a.o_collaborateur is null then
        raise exception 'Votre compte n''est rattaché à aucune fiche collaborateur : demande impossible.';
      end if;
      if a.o_collaborateur <> new.collaborateur_id then
        raise exception 'Vous ne pouvez demander des congés que pour vous-même.';
      end if;
    end if;
    if new.date_debut is null or new.date_fin is null then
      raise exception 'Dates de début et de fin obligatoires.';
    end if;
    if new.date_fin < new.date_debut then
      raise exception 'La date de fin précède la date de début.';
    end if;
    if new.date_fin = new.date_debut and new.debut_apres_midi and new.fin_midi then
      raise exception 'Demi-journées incohérentes : une absence d''un seul jour ne peut pas commencer l''après-midi et finir à midi.';
    end if;
    v_max := (public.abs_demi_fin(new.date_fin, new.fin_midi) - public.abs_demi_debut(new.date_debut, new.debut_apres_midi)) / 2.0;
    if new.nb_jours is null or new.nb_jours <= 0 then
      raise exception 'Le nombre de jours doit être strictement positif.';
    end if;
    if new.nb_jours * 2 <> trunc(new.nb_jours * 2) then
      raise exception 'Le nombre de jours se saisit par demi-journée (pas de 0,5).';
    end if;
    if new.nb_jours > v_max then
      raise exception 'Le nombre de jours (%) dépasse la période demandée (% jour(s) au plus, demi-journées comprises).',
        replace(trim_scale(new.nb_jours)::text, '.', ','), replace(trim_scale(v_max)::text, '.', ',');
    end if;
    if v_entree is not null and new.date_debut < v_entree then
      raise exception 'Absence refusée : elle commence avant l''entrée du collaborateur (%).', to_char(v_entree, 'DD/MM/YYYY');
    end if;
    if v_sortie is not null and new.date_fin > v_sortie then
      raise exception 'Absence refusée : le collaborateur quitte l''entreprise le % ; aucune absence ne peut être posée après.',
        to_char(v_sortie, 'DD/MM/YYYY');
    end if;
    if new.date_debut < v_aujourdhui then
      if a.o_role <> 'admin' then
        raise exception 'Une demande sur une date passée est réservée à l''administrateur (avec motif).';
      end if;
      if coalesce(btrim(new.motif_retroactif), '') = '' then
        raise exception 'Demande rétroactive : un motif est obligatoire.';
      end if;
      new.motif_retroactif := btrim(new.motif_retroactif);
    else
      new.motif_retroactif := null;
    end if;
    select c.date_debut, c.date_fin, c.statut into v_conflit
      from public.conges c
     where c.collaborateur_id = new.collaborateur_id and c.statut in ('demandee', 'validee')
       and public.abs_demi_debut(c.date_debut, c.debut_apres_midi) < public.abs_demi_fin(new.date_fin, new.fin_midi)
       and public.abs_demi_debut(new.date_debut, new.debut_apres_midi) < public.abs_demi_fin(c.date_fin, c.fin_midi)
     order by c.date_debut limit 1;
    if found then
      raise exception 'Chevauchement : une demande % existe déjà du % au % (demi-journées comprises).',
        case v_conflit.statut when 'validee' then 'validée' else 'en attente' end,
        to_char(v_conflit.date_debut, 'DD/MM/YYYY'), to_char(v_conflit.date_fin, 'DD/MM/YYYY');
    end if;
    new.motif := nullif(btrim(new.motif), '');
    new.essai := public.abs_fiche_essai(v_email);
    new.demande_par := a.o_id;
    new.demande_par_nom := a.o_nom;
    new.demande_le := now();
    new.historique := jsonb_build_array(jsonb_build_object('action', 'demande', 'le', now(), 'auteur', a.o_id,
      'auteur_nom', a.o_nom, 'pour_collaborateur', new.collaborateur_id, 'motif', new.motif_retroactif));
    return new;
  end if;

  -- Décision ------------------------------------------------------------------------------------------------------
  if new.historique is distinct from old.historique then
    raise exception 'Historique : alimenté par la base seulement, ni modifiable ni effaçable.';
  end if;
  if (new.id, new.collaborateur_id, new.type, new.date_debut, new.date_fin, new.debut_apres_midi, new.fin_midi, new.nb_jours,
      new.motif, new.motif_retroactif, new.demande_par, new.demande_par_nom, new.demande_le, new.created_at, new.essai)
     is distinct from
     (old.id, old.collaborateur_id, old.type, old.date_debut, old.date_fin, old.debut_apres_midi, old.fin_midi, old.nb_jours,
      old.motif, old.motif_retroactif, old.demande_par, old.demande_par_nom, old.demande_le, old.created_at, old.essai) then
    raise exception 'Le contenu d''une demande de congé ne se modifie pas : faites une nouvelle demande.';
  end if;
  if (new.valide_par, new.decide_par, new.decide_par_nom, new.decide_le, new.motif_decision, new.solde_preleve)
     is distinct from (old.valide_par, old.decide_par, old.decide_par_nom, old.decide_le, old.motif_decision, old.solde_preleve) then
    raise exception 'La décision et le prélèvement sont enregistrés par la base seulement.';
  end if;
  if new.statut is not distinct from old.statut then
    return new;
  end if;
  if v_op <> 'decider_conge' then
    raise exception 'Congés : la décision passe par l''application.';
  end if;
  if old.statut <> 'demandee' then
    raise exception 'Décision déjà prise (demande %) : une demande validée ou refusée ne change plus.',
      case old.statut when 'validee' then 'validée' else 'refusée' end;
  end if;
  if new.statut not in ('validee', 'refusee') then
    raise exception 'Décision inconnue.';
  end if;
  if a.o_collaborateur is not distinct from old.collaborateur_id then
    raise exception 'Personne ne décide de ses propres congés (administrateur compris).';
  end if;
  if not public.rh_est_valideur(a.o_role, a.o_collaborateur, old.collaborateur_id) then
    raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette demande.';
  end if;

  if new.statut = 'validee' then
    -- Verrou de la fiche (après celui de la demande, posé par la fonction de service) : deux validations de
    -- demandes différentes ne prélèvent jamais au-delà du solde.
    select solde_conges, solde_rtt,
           exists (select 1 from jsonb_array_elements(historique_soldes) e where e ->> 'type' = 'rtt' and e ->> 'action' = 'ajustement')
      into v_cp, v_rtt, v_rtt_renseigne
      from public.collaborateurs where id = old.collaborateur_id for update;
    v_preleve := case old.type when 'sans_solde' then 0 else old.nb_jours end;
    if old.type = 'conges_payes' and v_cp < old.nb_jours then
      raise exception 'Solde de congés payés insuffisant : % jour(s) disponible(s), % demandé(s). Validation refusée.',
        replace(trim_scale(v_cp)::text, '.', ','), replace(trim_scale(old.nb_jours)::text, '.', ',');
    end if;
    if old.type = 'rtt' and v_rtt < old.nb_jours then
      raise exception 'Solde RTT insuffisant : % jour(s) disponible(s), % demandé(s)%. Validation refusée.',
        replace(trim_scale(v_rtt)::text, '.', ','), replace(trim_scale(old.nb_jours)::text, '.', ','),
        case when v_rtt_renseigne then '' else ' (droits RTT non renseignés)' end;
    end if;
    if v_preleve > 0 then
      perform set_config('sgi.abs_operation', 'prelevement', true);
      perform set_config('sgi.abs_evenement', jsonb_build_object('type', old.type, 'action', 'prelevement', 'conge', old.id,
        'jours', v_preleve, 'auteur', a.o_id, 'auteur_nom', a.o_nom, 'motif', null)::text, true);
      if old.type = 'conges_payes' then
        update public.collaborateurs set solde_conges = solde_conges - v_preleve where id = old.collaborateur_id;
      else
        update public.collaborateurs set solde_rtt = solde_rtt - v_preleve where id = old.collaborateur_id;
      end if;
      perform set_config('sgi.abs_operation', 'decider_conge', true);
    end if;
    new.solde_preleve := v_preleve;
    new.valide_par := a.o_collaborateur;
    v_evt := jsonb_build_object('action', 'validation', 'le', now(), 'auteur', a.o_id, 'auteur_nom', a.o_nom,
      'solde_preleve', v_preleve, 'motif', v_motif);
  else
    if v_motif is null then
      raise exception 'Refus : un motif est obligatoire.';
    end if;
    v_evt := jsonb_build_object('action', 'refus', 'le', now(), 'auteur', a.o_id, 'auteur_nom', a.o_nom, 'motif', v_motif);
  end if;
  new.decide_par := a.o_id;
  new.decide_par_nom := a.o_nom;
  new.decide_le := now();
  new.motif_decision := v_motif;
  new.historique := old.historique || jsonb_build_array(v_evt);
  return new;
end
$$;
drop trigger if exists conges_controle on public.conges;
create trigger conges_controle before insert or update or delete on public.conges
  for each row execute function public.conges_controle();

-- 5c. Notes de frais : toutes les règles, quel que soit le chemin d'écriture.
create or replace function public.notes_de_frais_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := nullif(current_setting('sgi.abs_operation', true), '');
  v_motif text := nullif(btrim(coalesce(current_setting('sgi.abs_motif', true), '')), '');
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  a record;
  v_email text;
  v_contenu boolean;
  v_justif boolean;
  v_evt jsonb;
begin
  if tg_op = 'DELETE' then
    if v_op = 'nettoyage_essais' and old.essai then
      return old;
    end if;
    raise exception 'Une note de frais ne se supprime pas (historique conservé).';
  end if;
  if v_op is null then
    raise exception 'Notes de frais : écriture directe interdite ; passez par l''application.';
  end if;
  select * into a from public.abs_auteur_courant();

  -- Création ------------------------------------------------------------------------------------------------------
  if tg_op = 'INSERT' then
    if v_op <> 'creer_note' then
      raise exception 'Notes de frais : une note se crée par l''application seulement.';
    end if;
    if new.statut <> 'soumise' or new.decide_par is not null or new.decide_par_nom is not null or new.decide_le is not null
       or new.motif_decision is not null or new.rembourse_le is not null or new.reference_remboursement is not null
       or new.rembourse_declare_par is not null or new.rembourse_declare_par_nom is not null or new.rembourse_declare_le is not null
       or new.historique is distinct from '[]'::jsonb then
      raise exception 'Une note de frais naît « soumise », sans décision, remboursement ni historique.';
    end if;
    select email into v_email from public.collaborateurs where id = new.collaborateur_id;
    if not found then
      raise exception 'Fiche collaborateur introuvable.';
    end if;
    if a.o_role <> 'admin' then
      if a.o_collaborateur is null then
        raise exception 'Votre compte n''est rattaché à aucune fiche collaborateur : note de frais impossible.';
      end if;
      if a.o_collaborateur <> new.collaborateur_id then
        raise exception 'Vous ne pouvez déposer des notes de frais que pour vous-même.';
      end if;
    end if;
    perform public.abs_controler_contenu_note(new.collaborateur_id, new.date_depense, new.categorie, new.categorie_precision, new.objet);
    perform public.abs_controler_justificatif(new.collaborateur_id, new.id, new.justificatif_url, new.justificatif_type,
      new.justificatif_taille, new.justificatif_empreinte);
    new.objet := btrim(new.objet);
    new.categorie_precision := nullif(btrim(new.categorie_precision), '');
    new.essai := public.abs_fiche_essai(v_email);
    new.justificatif_depose_le := now();
    new.soumise_par := a.o_id;
    new.soumise_par_nom := a.o_nom;
    new.soumise_le := now();
    new.historique := jsonb_build_array(jsonb_build_object('action', 'soumission', 'le', now(), 'auteur', a.o_id,
      'auteur_nom', a.o_nom, 'pour_collaborateur', new.collaborateur_id, 'justificatif_url', new.justificatif_url,
      'justificatif_empreinte', new.justificatif_empreinte, 'motif', null));
    return new;
  end if;

  -- Modification --------------------------------------------------------------------------------------------------
  if new.historique is distinct from old.historique then
    raise exception 'Historique : alimenté par la base seulement, ni modifiable ni effaçable.';
  end if;
  if (new.id, new.collaborateur_id, new.created_at, new.soumise_par, new.soumise_par_nom, new.soumise_le, new.essai)
     is distinct from (old.id, old.collaborateur_id, old.created_at, old.soumise_par, old.soumise_par_nom, old.soumise_le, old.essai) then
    raise exception 'Le collaborateur, l''auteur et la date de dépôt d''une note ne changent pas.';
  end if;
  if (new.decide_par, new.decide_par_nom, new.decide_le, new.motif_decision, new.rembourse_declare_par,
      new.rembourse_declare_par_nom, new.rembourse_declare_le, new.justificatif_depose_le)
     is distinct from (old.decide_par, old.decide_par_nom, old.decide_le, old.motif_decision, old.rembourse_declare_par,
      old.rembourse_declare_par_nom, old.rembourse_declare_le, old.justificatif_depose_le) then
    raise exception 'Décision, déclaration de remboursement et date de dépôt : enregistrées par la base seulement.';
  end if;
  v_contenu := (new.date_depense, new.montant, new.categorie, new.categorie_precision, new.objet)
               is distinct from (old.date_depense, old.montant, old.categorie, old.categorie_precision, old.objet);
  v_justif := (new.justificatif_url, new.justificatif_empreinte, new.justificatif_taille, new.justificatif_type)
              is distinct from (old.justificatif_url, old.justificatif_empreinte, old.justificatif_taille, old.justificatif_type);

  if v_contenu or v_justif then
    if old.statut <> 'soumise' or new.statut <> 'soumise' then
      raise exception 'Note % : son contenu et son justificatif ne se modifient plus.',
        case old.statut when 'validee' then 'validée' when 'refusee' then 'refusée' when 'remboursee' then 'remboursée' else 'soumise' end;
    end if;
    if v_op <> 'modifier_note' then
      raise exception 'Notes de frais : la modification passe par l''application.';
    end if;
    if (new.rembourse_le, new.reference_remboursement) is distinct from (old.rembourse_le, old.reference_remboursement) then
      raise exception 'Le remboursement ne se déclare pas avec une modification de contenu.';
    end if;
    if a.o_role <> 'admin' and a.o_collaborateur is distinct from old.collaborateur_id then
      raise exception 'Vous ne pouvez modifier que vos propres notes de frais.';
    end if;
    perform public.abs_controler_contenu_note(new.collaborateur_id, new.date_depense, new.categorie, new.categorie_precision, new.objet);
    if v_justif then
      perform public.abs_controler_justificatif(new.collaborateur_id, new.id, new.justificatif_url, new.justificatif_type,
        new.justificatif_taille, new.justificatif_empreinte);
      new.justificatif_depose_le := now();
    end if;
    new.objet := btrim(new.objet);
    new.categorie_precision := nullif(btrim(new.categorie_precision), '');
    new.historique := old.historique || jsonb_build_array(jsonb_build_object('action', 'modification', 'le', now(),
      'auteur', a.o_id, 'auteur_nom', a.o_nom, 'motif', null,
      'avant', jsonb_build_object('date_depense', old.date_depense, 'montant', old.montant, 'categorie', old.categorie,
        'categorie_precision', old.categorie_precision, 'objet', old.objet, 'justificatif_url', old.justificatif_url,
        'justificatif_empreinte', old.justificatif_empreinte, 'justificatif_type', old.justificatif_type,
        'justificatif_taille', old.justificatif_taille)));
    return new;
  end if;

  if new.statut is not distinct from old.statut
     and (new.rembourse_le, new.reference_remboursement) is not distinct from (old.rembourse_le, old.reference_remboursement) then
    return new;
  end if;

  if old.statut = 'soumise' and new.statut in ('validee', 'refusee') then
    if v_op <> 'decider_note' then
      raise exception 'Notes de frais : la décision passe par l''application.';
    end if;
    if new.rembourse_le is not null or new.reference_remboursement is not null then
      raise exception 'Le remboursement se déclare après la validation.';
    end if;
    if a.o_collaborateur is not distinct from old.collaborateur_id then
      raise exception 'Personne ne décide de ses propres notes de frais (administrateur compris).';
    end if;
    if not public.rh_est_valideur(a.o_role, a.o_collaborateur, old.collaborateur_id) then
      raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette note.';
    end if;
    if new.statut = 'refusee' and v_motif is null then
      raise exception 'Refus : un motif est obligatoire.';
    end if;
    new.decide_par := a.o_id;
    new.decide_par_nom := a.o_nom;
    new.decide_le := now();
    new.motif_decision := v_motif;
    v_evt := jsonb_build_object('action', case new.statut when 'validee' then 'validation' else 'refus' end, 'le', now(),
      'auteur', a.o_id, 'auteur_nom', a.o_nom, 'motif', v_motif);

  elsif old.statut = 'validee' and new.statut = 'remboursee' then
    if v_op <> 'rembourser' then
      raise exception 'Notes de frais : le remboursement se déclare par l''application.';
    end if;
    if a.o_role <> 'admin' then
      raise exception 'Seul l''administrateur déclare un remboursement.';
    end if;
    if a.o_collaborateur is not distinct from old.collaborateur_id then
      raise exception 'Personne ne déclare le remboursement de ses propres notes de frais.';
    end if;
    if new.rembourse_le is null or new.rembourse_le > v_aujourdhui or new.rembourse_le < old.date_depense then
      raise exception 'Date de remboursement obligatoire, ni future ni antérieure à la dépense.';
    end if;
    new.reference_remboursement := nullif(btrim(new.reference_remboursement), '');
    new.rembourse_declare_par := a.o_id;
    new.rembourse_declare_par_nom := a.o_nom;
    new.rembourse_declare_le := now();
    v_evt := jsonb_build_object('action', 'remboursement_declare', 'le', now(), 'auteur', a.o_id, 'auteur_nom', a.o_nom,
      'rembourse_le', new.rembourse_le, 'reference', new.reference_remboursement, 'motif', null);

  elsif old.statut = 'remboursee' and new.statut in ('validee', 'remboursee') then
    if v_op <> 'corriger_remboursement' then
      raise exception 'Notes de frais : la correction d''un remboursement passe par l''application.';
    end if;
    if a.o_role <> 'admin' then
      raise exception 'Seul l''administrateur corrige une déclaration de remboursement.';
    end if;
    if a.o_collaborateur is not distinct from old.collaborateur_id then
      raise exception 'Personne ne corrige le remboursement de ses propres notes de frais.';
    end if;
    if v_motif is null then
      raise exception 'Correction : un motif est obligatoire.';
    end if;
    if new.statut = 'validee' then
      if new.rembourse_le is not null or new.reference_remboursement is not null then
        raise exception 'Annulation : la date et la référence de remboursement sont effacées.';
      end if;
      new.rembourse_declare_par := null;
      new.rembourse_declare_par_nom := null;
      new.rembourse_declare_le := null;
    else
      if new.rembourse_le is null or new.rembourse_le > v_aujourdhui or new.rembourse_le < old.date_depense then
        raise exception 'Date de remboursement obligatoire, ni future ni antérieure à la dépense.';
      end if;
      new.reference_remboursement := nullif(btrim(new.reference_remboursement), '');
      new.rembourse_declare_par := a.o_id;
      new.rembourse_declare_par_nom := a.o_nom;
      new.rembourse_declare_le := now();
    end if;
    v_evt := jsonb_build_object('action', case new.statut when 'validee' then 'remboursement_annule' else 'remboursement_corrige' end,
      'le', now(), 'auteur', a.o_id, 'auteur_nom', a.o_nom, 'motif', v_motif,
      'avant', jsonb_build_object('rembourse_le', old.rembourse_le, 'reference', old.reference_remboursement,
        'declare_par_nom', old.rembourse_declare_par_nom, 'declare_le', old.rembourse_declare_le),
      'apres', jsonb_build_object('rembourse_le', new.rembourse_le, 'reference', new.reference_remboursement));
  else
    raise exception 'Changement non permis pour une note de frais : % → %.', old.statut, new.statut;
  end if;
  new.historique := old.historique || jsonb_build_array(v_evt);
  return new;
end
$$;
drop trigger if exists notes_de_frais_controle on public.notes_de_frais;
create trigger notes_de_frais_controle before insert or update or delete on public.notes_de_frais
  for each row execute function public.notes_de_frais_controle();

-- 6. Fonctions de service (clé secrète seulement, appelées par les actions serveur après vérification) ------------
-- 6a. Demande de congé (pour soi ; l'administrateur peut demander pour autrui, tracé).
create or replace function public.abs_demander_conge(p_auteur uuid, p_collaborateur uuid, p_type text, p_debut date, p_fin date,
  p_debut_apres_midi boolean, p_fin_midi boolean, p_nb_jours numeric, p_motif text, p_motif_retroactif text)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_type is null or p_type not in ('conges_payes', 'rtt', 'sans_solde') then
    raise exception 'Type d''absence inconnu : congés payés, RTT ou sans solde.';
  end if;
  -- La colonne arrondirait en silence : un nombre de jours hors pas de 0,5 est refusé ici, avec un message.
  if p_nb_jours is null or p_nb_jours <= 0 then
    raise exception 'Le nombre de jours doit être strictement positif.';
  end if;
  if p_nb_jours * 2 <> trunc(p_nb_jours * 2) then
    raise exception 'Le nombre de jours se saisit par demi-journée (pas de 0,5).';
  end if;
  perform public.abs_contexte(p_auteur, 'demander_conge', null);
  insert into public.conges (collaborateur_id, type, date_debut, date_fin, debut_apres_midi, fin_midi, nb_jours, motif, motif_retroactif)
  values (p_collaborateur, p_type, p_debut, p_fin, coalesce(p_debut_apres_midi, false), coalesce(p_fin_midi, false), p_nb_jours,
          p_motif, p_motif_retroactif)
  returning id into v_id;
  perform public.abs_fin_contexte();
  return v_id;
end
$$;

-- 6b. Décision sur un congé. Verrou de la demande, puis (dans le déclencheur) de la fiche. Rejouée (double clic,
--     deux onglets) : renvoie la décision déjà prise sans nouveau prélèvement.
create or replace function public.abs_decider_conge(p_auteur uuid, p_conge uuid, p_decision text, p_motif text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_role text;
  v_collab_auteur uuid;
  v_statut text;
  v_collab uuid;
  v_cible text;
begin
  v_cible := case p_decision when 'valider' then 'validee' when 'refuser' then 'refusee' end;
  if v_cible is null then
    raise exception 'Décision inconnue : %.', p_decision;
  end if;
  v_role := public.abs_contexte(p_auteur, 'decider_conge', p_motif);
  select statut, collaborateur_id into v_statut, v_collab from public.conges where id = p_conge for update;
  if not found then
    raise exception 'Demande de congé introuvable.';
  end if;
  select collaborateur_id into v_collab_auteur from public.profiles where id = p_auteur;
  if v_collab_auteur is not distinct from v_collab then
    raise exception 'Personne ne décide de ses propres congés (administrateur compris).';
  end if;
  if not public.rh_est_valideur(v_role, v_collab_auteur, v_collab) then
    raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette demande.';
  end if;
  if v_statut = v_cible then
    perform public.abs_fin_contexte();
    return jsonb_build_object('statut', v_statut, 'deja_decide', true);
  end if;
  update public.conges set statut = v_cible where id = p_conge;
  perform public.abs_fin_contexte();
  return jsonb_build_object('statut', v_cible, 'deja_decide', false);
end
$$;

-- 6c. Ajustement d'un solde (administrateur, motif ; jamais sur sa propre fiche). La valeur affichée à l'écran est
--     transmise : si le solde a changé entre-temps (validation simultanée), l'ajustement est refusé.
create or replace function public.abs_ajuster_solde(p_auteur uuid, p_collaborateur uuid, p_type text, p_ancien numeric,
  p_nouveau numeric, p_motif text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_role text;
  v_nom text;
  v_actuel numeric;
begin
  v_role := public.abs_contexte(p_auteur, 'ajustement', p_motif);
  if v_role <> 'admin' then
    raise exception 'Ajustement des soldes réservé à l''administrateur.';
  end if;
  if exists (select 1 from public.profiles where id = p_auteur and collaborateur_id = p_collaborateur) then
    raise exception 'Vous ne pouvez pas ajuster votre propre solde.';
  end if;
  if p_type is null or p_type not in ('conges_payes', 'rtt') then
    raise exception 'Solde inconnu : congés payés ou RTT.';
  end if;
  if coalesce(btrim(p_motif), '') = '' then
    raise exception 'Ajustement : un motif est obligatoire.';
  end if;
  if p_nouveau is null or p_nouveau < 0 then
    raise exception 'Un solde est positif ou nul.';
  end if;
  if p_nouveau * 100 <> trunc(p_nouveau * 100) or p_nouveau >= 10000 then
    raise exception 'Solde : au plus 2 décimales et moins de 10 000 jours.';
  end if;
  select case p_type when 'rtt' then solde_rtt else solde_conges end into v_actuel
    from public.collaborateurs where id = p_collaborateur for update;
  if not found then
    raise exception 'Fiche collaborateur introuvable.';
  end if;
  if p_ancien is null or v_actuel <> p_ancien then
    raise exception 'Le solde a changé entre-temps (% au lieu de %) : rechargez la page avant d''ajuster.',
      replace(trim_scale(v_actuel)::text, '.', ','), coalesce(replace(trim_scale(p_ancien)::text, '.', ','), 'non transmis');
  end if;
  select coalesce(nullif(nom, ''), email) into v_nom from public.profiles where id = p_auteur;
  perform set_config('sgi.abs_evenement', jsonb_build_object('type', p_type, 'action', 'ajustement', 'auteur', p_auteur,
    'auteur_nom', v_nom, 'motif', btrim(p_motif))::text, true);
  if p_type = 'rtt' then
    update public.collaborateurs set solde_rtt = p_nouveau where id = p_collaborateur;
  else
    update public.collaborateurs set solde_conges = p_nouveau where id = p_collaborateur;
  end if;
  if coalesce(current_setting('sgi.abs_evenement', true), '') <> '' then
    raise exception 'Ajustement non inscrit dans l''historique des soldes.';
  end if;
  perform public.abs_fin_contexte();
end
$$;

-- 6d. Note de frais : création. Rejouée avec le même fichier (réponse perdue, double clic) : renvoie la note déjà
--     créée, sans doublon. Deux créations simultanées avec le même fichier : l'index unique en arrête une.
create or replace function public.abs_creer_note(p_auteur uuid, p_collaborateur uuid, p_date date, p_montant numeric,
  p_categorie text, p_precision text, p_objet text, p_chemin text, p_type text, p_taille bigint, p_empreinte text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
  v_collab uuid;
  v_empreinte text;
begin
  if p_montant is null or p_montant <= 0 then
    raise exception 'Le montant TTC doit être strictement positif.';
  end if;
  if p_montant * 100 <> trunc(p_montant * 100) or p_montant >= 100000000 then
    raise exception 'Montant : au plus 2 décimales (la base arrondirait en silence) et moins de 100 000 000 €.';
  end if;
  perform public.abs_contexte(p_auteur, 'creer_note', null);
  select id, collaborateur_id, justificatif_empreinte into v_id, v_collab, v_empreinte
    from public.notes_de_frais where justificatif_url = p_chemin;
  if v_id is null then
    begin
      insert into public.notes_de_frais (collaborateur_id, date_depense, montant, categorie, categorie_precision, objet,
        justificatif_url, justificatif_type, justificatif_taille, justificatif_empreinte)
      values (p_collaborateur, p_date, p_montant, p_categorie, p_precision, p_objet, p_chemin, p_type, p_taille, p_empreinte)
      returning id into v_id;
      perform public.abs_fin_contexte();
      return jsonb_build_object('id', v_id, 'deja_creee', false);
    exception when unique_violation then
      select id, collaborateur_id, justificatif_empreinte into v_id, v_collab, v_empreinte
        from public.notes_de_frais where justificatif_url = p_chemin;
    end;
  end if;
  if v_collab is distinct from p_collaborateur or v_empreinte is distinct from p_empreinte then
    raise exception 'Justificatif déjà rattaché à une autre note de frais.';
  end if;
  perform public.abs_fin_contexte();
  return jsonb_build_object('id', v_id, 'deja_creee', true);
end
$$;

-- 6e. Modification d'une note encore « soumise » (p_chemin null : justificatif conservé). L'ancien justificatif
--     reste dans l'historique et dans le stockage (jamais supprimé).
create or replace function public.abs_modifier_note(p_auteur uuid, p_note uuid, p_date date, p_montant numeric,
  p_categorie text, p_precision text, p_objet text, p_chemin text, p_type text, p_taille bigint, p_empreinte text)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_montant is null or p_montant <= 0 then
    raise exception 'Le montant TTC doit être strictement positif.';
  end if;
  if p_montant * 100 <> trunc(p_montant * 100) or p_montant >= 100000000 then
    raise exception 'Montant : au plus 2 décimales (la base arrondirait en silence) et moins de 100 000 000 €.';
  end if;
  perform public.abs_contexte(p_auteur, 'modifier_note', null);
  perform 1 from public.notes_de_frais where id = p_note for update;
  if not found then
    raise exception 'Note de frais introuvable.';
  end if;
  if p_chemin is null then
    update public.notes_de_frais
       set date_depense = p_date, montant = p_montant, categorie = p_categorie, categorie_precision = p_precision, objet = p_objet
     where id = p_note;
  else
    update public.notes_de_frais
       set date_depense = p_date, montant = p_montant, categorie = p_categorie, categorie_precision = p_precision, objet = p_objet,
           justificatif_url = p_chemin, justificatif_type = p_type, justificatif_taille = p_taille, justificatif_empreinte = p_empreinte
     where id = p_note;
  end if;
  perform public.abs_fin_contexte();
end
$$;

-- 6f. Décision sur une note (validation, refus motivé). Rejouée : renvoie la décision déjà prise.
create or replace function public.abs_decider_note(p_auteur uuid, p_note uuid, p_decision text, p_motif text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_role text;
  v_collab_auteur uuid;
  v_statut text;
  v_collab uuid;
  v_cible text;
begin
  v_cible := case p_decision when 'valider' then 'validee' when 'refuser' then 'refusee' end;
  if v_cible is null then
    raise exception 'Décision inconnue : %.', p_decision;
  end if;
  v_role := public.abs_contexte(p_auteur, 'decider_note', p_motif);
  select statut, collaborateur_id into v_statut, v_collab from public.notes_de_frais where id = p_note for update;
  if not found then
    raise exception 'Note de frais introuvable.';
  end if;
  select collaborateur_id into v_collab_auteur from public.profiles where id = p_auteur;
  if v_collab_auteur is not distinct from v_collab then
    raise exception 'Personne ne décide de ses propres notes de frais (administrateur compris).';
  end if;
  if not public.rh_est_valideur(v_role, v_collab_auteur, v_collab) then
    raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette note.';
  end if;
  if v_statut = v_cible then
    perform public.abs_fin_contexte();
    return jsonb_build_object('statut', v_statut, 'deja_decide', true);
  end if;
  if v_statut <> 'soumise' then
    raise exception 'Décision déjà prise : cette note n''est plus « soumise ».';
  end if;
  update public.notes_de_frais set statut = v_cible where id = p_note;
  perform public.abs_fin_contexte();
  return jsonb_build_object('statut', v_cible, 'deja_decide', false);
end
$$;

-- 6g. Remboursement DÉCLARÉ par l'administrateur (aucun virement n'est fait par l'application). Rejoué avec les
--     mêmes valeurs : sans effet.
create or replace function public.abs_declarer_remboursement(p_auteur uuid, p_note uuid, p_date date, p_reference text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_statut text;
  v_date date;
  v_ref text;
begin
  perform public.abs_contexte(p_auteur, 'rembourser', null);
  select statut, rembourse_le, reference_remboursement into v_statut, v_date, v_ref
    from public.notes_de_frais where id = p_note for update;
  if not found then
    raise exception 'Note de frais introuvable.';
  end if;
  if v_statut = 'remboursee' then
    if v_date = p_date and v_ref is not distinct from nullif(btrim(p_reference), '') then
      perform public.abs_fin_contexte();
      return jsonb_build_object('statut', v_statut, 'deja_declare', true);
    end if;
    raise exception 'Remboursement déjà déclaré : utilisez la correction motivée.';
  end if;
  if v_statut <> 'validee' then
    raise exception 'Seule une note validée se rembourse.';
  end if;
  update public.notes_de_frais set statut = 'remboursee', rembourse_le = p_date, reference_remboursement = p_reference
   where id = p_note;
  perform public.abs_fin_contexte();
  return jsonb_build_object('statut', 'remboursee', 'deja_declare', false);
end
$$;

-- 6h. Correction d'une déclaration de remboursement : « annuler » (retour à « validée ») ou « corriger » (date,
--     référence). Administrateur, motif obligatoire ; valeurs précédentes conservées dans l'historique.
create or replace function public.abs_corriger_remboursement(p_auteur uuid, p_note uuid, p_action text, p_date date,
  p_reference text, p_motif text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_statut text;
begin
  if p_action is null or p_action not in ('annuler', 'corriger') then
    raise exception 'Correction inconnue : annuler ou corriger.';
  end if;
  perform public.abs_contexte(p_auteur, 'corriger_remboursement', p_motif);
  select statut into v_statut from public.notes_de_frais where id = p_note for update;
  if not found then
    raise exception 'Note de frais introuvable.';
  end if;
  if v_statut <> 'remboursee' then
    raise exception 'Aucun remboursement déclaré sur cette note.';
  end if;
  if p_action = 'annuler' then
    update public.notes_de_frais set statut = 'validee', rembourse_le = null, reference_remboursement = null where id = p_note;
  else
    if exists (select 1 from public.notes_de_frais where id = p_note and rembourse_le = p_date
                and reference_remboursement is not distinct from nullif(btrim(p_reference), '')) then
      raise exception 'Correction : aucune valeur ne change.';
    end if;
    update public.notes_de_frais set rembourse_le = p_date, reference_remboursement = p_reference where id = p_note;
  end if;
  perform public.abs_fin_contexte();
end
$$;

-- 6i. Fichiers : un fichier est « rattaché » s'il est le justificatif d'une note ou figure dans son historique.
create or replace function public.abs_justificatif_rattache(p_chemin text)
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (select 1 from public.notes_de_frais n
                  where n.justificatif_url = p_chemin or strpos(n.historique::text, p_chemin) > 0);
$$;

-- Dépôts abandonnés : plus d'une heure, jamais rattachés (un rattachement n'est possible que dans les 30 minutes).
create or replace function public.abs_fichiers_orphelins()
returns setof text
language sql
stable
set search_path = public
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'justificatifs' and o.created_at < now() - interval '1 hour'
     and not public.abs_justificatif_rattache(o.name)
   order by o.name;
$$;

-- 6j. Nettoyage des essais (clé secrète) : congés et notes des fiches d'essai (@exemple.invalid). Renvoie les
--     fichiers à retirer du stockage (justificatifs actuels et anciens de ces notes seulement). Rien de réel.
create or replace function public.supprimer_essais_absences()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_chemins text[];
  v_conges integer;
  v_notes integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé aux essais autorisés (clé secrète)';
  end if;
  select coalesce(array_agg(distinct c), '{}') into v_chemins
    from (select n.justificatif_url as c from public.notes_de_frais n where n.essai
          union
          select e ->> 'justificatif_url' from public.notes_de_frais n, jsonb_array_elements(n.historique) e where n.essai
          union
          select e -> 'avant' ->> 'justificatif_url' from public.notes_de_frais n, jsonb_array_elements(n.historique) e where n.essai) x
   where c is not null;
  perform public.abs_fin_contexte();
  perform set_config('sgi.abs_operation', 'nettoyage_essais', true);
  delete from public.notes_de_frais where essai;
  get diagnostics v_notes = row_count;
  delete from public.conges where essai;
  get diagnostics v_conges = row_count;
  perform public.abs_fin_contexte();
  -- Un fichier encore rattaché à une note réelle n'est jamais rendu.
  select coalesce(array_agg(c), '{}') into v_chemins from unnest(v_chemins) c where not public.abs_justificatif_rattache(c);
  return jsonb_build_object('conges', v_conges, 'notes', v_notes, 'chemins', to_jsonb(v_chemins));
end
$$;

do $$
declare
  v_fonction text;
begin
  foreach v_fonction in array array[
    'abs_contexte(uuid, text, text)', 'abs_fin_contexte()', 'abs_auteur_courant()', 'abs_demi_debut(date, boolean)',
    'abs_demi_fin(date, boolean)', 'abs_fiche_essai(text)',
    'abs_controler_justificatif(uuid, uuid, text, text, bigint, text)', 'abs_controler_contenu_note(uuid, date, text, text, text)',
    'abs_demander_conge(uuid, uuid, text, date, date, boolean, boolean, numeric, text, text)',
    'abs_decider_conge(uuid, uuid, text, text)', 'abs_ajuster_solde(uuid, uuid, text, numeric, numeric, text)',
    'abs_creer_note(uuid, uuid, date, numeric, text, text, text, text, text, bigint, text)',
    'abs_modifier_note(uuid, uuid, date, numeric, text, text, text, text, text, bigint, text)',
    'abs_decider_note(uuid, uuid, text, text)', 'abs_declarer_remboursement(uuid, uuid, date, text)',
    'abs_corriger_remboursement(uuid, uuid, text, date, text, text)', 'abs_justificatif_rattache(text)',
    'abs_fichiers_orphelins()', 'supprimer_essais_absences()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    execute format('grant execute on function public.%s to service_role', v_fonction);
  end loop;
end
$$;

-- 7. Droits -------------------------------------------------------------------------------------------------------
-- 7a. Congés et notes : lecture de ses propres lignes ; le manager, celles de son équipe directe ; l'admin, tout.
--     Aucune écriture avec un jeton : tout passe par les fonctions de service.
do $$
declare
  v_regle record;
begin
  for v_regle in select policyname, tablename from pg_policies
                  where schemaname = 'public' and tablename in ('conges', 'notes_de_frais') loop
    execute format('drop policy if exists %I on public.%I', v_regle.policyname, v_regle.tablename);
  end loop;
end
$$;
create policy "conges_lecture_soi_equipe_admin" on public.conges for select to authenticated
  using (collaborateur_id = (select public.mon_collaborateur_id())
         or (select public.est_admin())
         or ((select public.mon_role()) = 'manager'
             and exists (select 1 from public.collaborateurs c
                          where c.id = conges.collaborateur_id and c.manager_id = (select public.mon_collaborateur_id()))));
create policy "notes_de_frais_lecture_soi_equipe_admin" on public.notes_de_frais for select to authenticated
  using (collaborateur_id = (select public.mon_collaborateur_id())
         or (select public.est_admin())
         or ((select public.mon_role()) = 'manager'
             and exists (select 1 from public.collaborateurs c
                          where c.id = notes_de_frais.collaborateur_id and c.manager_id = (select public.mon_collaborateur_id()))));
revoke all on public.conges from anon, authenticated;
grant select on public.conges to authenticated;
revoke all on public.notes_de_frais from anon, authenticated;
grant select on public.notes_de_frais to authenticated;

-- 7b. Fiches : soldes et historique des soldes illisibles et non modifiables avec un jeton (la lecture de
--     solde_conges par tous les managers est fermée). Écriture des fiches (admin) : les autres colonnes, inchangées.
do $$
declare
  v_colonnes text;
begin
  execute 'revoke select (solde_conges) on public.collaborateurs from authenticated';
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_colonnes
    from information_schema.columns
   where table_schema = 'public' and table_name = 'collaborateurs'
     and column_name not in ('solde_conges', 'solde_rtt', 'historique_soldes');
  execute 'revoke insert, update on public.collaborateurs from authenticated';
  execute format('grant insert (%s) on public.collaborateurs to authenticated', v_colonnes);
  execute format('grant update (%s) on public.collaborateurs to authenticated', v_colonnes);
end
$$;

-- 7c. Soldes : vue filtrée par les fonctions d'identité (session active) — soi, équipe directe du manager, admin.
drop view if exists public.absences_soldes;
create view public.absences_soldes with (security_barrier = true) as
  select c.id, c.nom, c.prenom, c.manager_id, c.date_sortie, c.solde_conges, c.solde_rtt, c.historique_soldes,
         exists (select 1 from jsonb_array_elements(c.historique_soldes) e
                  where e ->> 'type' = 'rtt' and e ->> 'action' = 'ajustement') as droits_rtt_renseignes
    from public.collaborateurs c
   where c.id = (select public.mon_collaborateur_id())
      or (select public.est_admin())
      or ((select public.mon_role()) = 'manager' and c.manager_id = (select public.mon_collaborateur_id()));
revoke all on public.absences_soldes from public, anon, authenticated;
grant select on public.absences_soldes to authenticated, service_role;

-- 7d. Bucket « justificatifs » : plus AUCUN accès direct avec un jeton (même admin) ; dépôt par lien signé émis par
--     le serveur après contrôle des droits, consultation par lien temporaire après contrôle de l'empreinte.
--     Le stockage refuse en plus tout fichier de plus de 10 Mo ou d'un type déclaré autre que PDF, JPEG, PNG.
do $$
declare
  v_regle record;
begin
  for v_regle in select policyname from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and (coalesce(qual, '') || coalesce(with_check, '')) like '%justificatifs%' loop
    execute format('drop policy if exists %I on storage.objects', v_regle.policyname);
  end loop;
end
$$;
update storage.buckets
   set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
 where id = 'justificatifs';

-- 8. Contrôles finaux et autotest (annulé) ----------------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_admin uuid;
  v_admin_fiche uuid;
  v_j date := (now() at time zone 'America/Martinique')::date;
  v_a uuid;
  v_m uuid;
  v_c1 uuid;
  v_c2 uuid;
  v_c3 uuid;
  v_res jsonb;
  v_res2 jsonb;
  v_note uuid;
  v_chemin text;
  v_chemin2 text;
  v_stockage boolean := true;
  v_avant text;
  v_apres text;
begin
  -- Fonctions appelables avec un jeton : toujours exactement les 4 fonctions d'identité ; aucune pour le visiteur.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Absences : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Absences : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'Absences : fonction(s) lisant le coût interne taux_horaire : %', v_liste;
  end if;
  -- Soldes : aucune colonne lisible ni modifiable avec un jeton ; taux toujours illisible.
  select string_agg(column_name, ', ') into v_liste
    from information_schema.columns
   where table_schema = 'public' and table_name = 'collaborateurs'
     and column_name in ('solde_conges', 'solde_rtt', 'historique_soldes', 'taux_horaire')
     and (has_column_privilege('authenticated', 'public.collaborateurs', column_name, 'select')
          or has_column_privilege('anon', 'public.collaborateurs', column_name, 'select')
          or (column_name <> 'taux_horaire'
              and (has_column_privilege('authenticated', 'public.collaborateurs', column_name, 'update')
                   or has_column_privilege('authenticated', 'public.collaborateurs', column_name, 'insert'))));
  if v_liste is not null then
    raise exception 'Absences : colonnes de fiche accessibles avec un jeton : %', v_liste;
  end if;
  -- Écritures existantes des écrans (Utilisateurs : création de fiche avec le jeton admin) toujours possibles.
  if not has_column_privilege('authenticated', 'public.collaborateurs', 'taux_horaire', 'insert')
     or not has_column_privilege('authenticated', 'public.collaborateurs', 'nom', 'insert')
     or not has_column_privilege('authenticated', 'public.collaborateurs', 'date_sortie', 'select') then
    raise exception 'Absences : écritures ou lectures existantes des fiches cassées';
  end if;
  if has_table_privilege('authenticated', 'public.conges', 'insert') or has_table_privilege('authenticated', 'public.conges', 'update')
     or has_table_privilege('authenticated', 'public.conges', 'delete')
     or has_table_privilege('authenticated', 'public.notes_de_frais', 'insert')
     or has_table_privilege('authenticated', 'public.notes_de_frais', 'update')
     or has_table_privilege('authenticated', 'public.notes_de_frais', 'delete')
     or has_table_privilege('anon', 'public.conges', 'select') or has_table_privilege('anon', 'public.notes_de_frais', 'select')
     or has_table_privilege('anon', 'public.absences_soldes', 'select') then
    raise exception 'Absences : droits d''écriture ou visiteur sur les congés ou les notes de frais';
  end if;
  select string_agg(tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'Absences : règles sans contrôle de session active : %', v_liste;
  end if;
  select string_agg(policyname, ', ') into v_liste from pg_policies
   where schemaname = 'storage' and (coalesce(qual, '') || coalesce(with_check, '')) like '%justificatifs%';
  if v_liste is not null then
    raise exception 'Absences : règle(s) d''accès direct au bucket justificatifs : %', v_liste;
  end if;
  if not exists (select 1 from storage.buckets where id = 'justificatifs' and not public and file_size_limit = 10485760
                    and allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']) then
    raise exception 'Absences : bucket justificatifs non privé ou sans limites';
  end if;
  select count(*) into v_nb from pg_trigger
   where not tgisinternal and tgname in ('collaborateurs_absences_controle', 'conges_controle', 'notes_de_frais_controle',
                                         'collaborateurs_avant_suppression', 'collaborateurs_avant_ecriture');
  if v_nb <> 5 then
    raise exception 'Absences : % déclencheurs sur 5 posés', v_nb;
  end if;
  -- Soldes existants : congés payés repris tels quels, RTT à 0 « non renseignés », pour chaque fiche.
  select count(*) into v_nb from public.collaborateurs
   where solde_rtt <> 0 or jsonb_array_length(historique_soldes) < 2
      or (historique_soldes -> 0 ->> 'apres')::numeric <> solde_conges
      or historique_soldes -> 1 ->> 'type' <> 'rtt';
  if v_nb > 0 then
    raise exception 'Absences : % fiche(s) avec des soldes initiaux incohérents', v_nb;
  end if;

  -- Autotest complet, annulé à la fin (fiches d'essai uniquement). Empreinte avant/après des tables touchées.
  select md5(coalesce((select string_agg(c::text, '|' order by c.id) from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.conges c), '')
          || coalesce((select string_agg(n::text, '|' order by n.id) from public.notes_de_frais n), '')
          || coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(o.name, '|' order by o.name) from storage.objects o where o.bucket_id = 'justificatifs'), ''))
    into v_avant;
  select id, collaborateur_id into v_admin, v_admin_fiche from public.profiles where role = 'admin' order by created_at limit 1;
  if v_admin is null then
    raise exception 'Absences : aucun compte admin, autotest impossible';
  end if;
  begin
    -- Fiches d'essai : M (manager de A) et A. Solde initial des congés payés : valeur de création (25 par défaut).
    insert into public.collaborateurs (nom, prenom, email) values ('Autotest-Absences', 'M', 'autotest-m@exemple.invalid')
      returning id into v_m;
    insert into public.collaborateurs (nom, prenom, email, manager_id) values ('Autotest-Absences', 'A', 'autotest-a@exemple.invalid', v_m)
      returning id into v_a;
    if (select solde_rtt <> 0 or jsonb_array_length(historique_soldes) <> 2 or historique_soldes -> 1 ->> 'action' <> 'initial'
          from public.collaborateurs where id = v_a) then
      raise exception 'AUTOTEST: soldes initiaux d''une nouvelle fiche incorrects';
    end if;
    begin
      insert into public.collaborateurs (nom, email, solde_rtt) values ('Autotest-Absences', 'autotest-x@exemple.invalid', 3);
      raise exception 'AUTOTEST: fiche créée avec un solde RTT';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.collaborateurs set solde_conges = 99 where id = v_a;
      raise exception 'AUTOTEST: solde modifié directement';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.collaborateurs set historique_soldes = '[]' where id = v_a;
      raise exception 'AUTOTEST: historique des soldes effacé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      insert into public.conges (collaborateur_id, date_debut, date_fin, nb_jours) values (v_a, v_j + 7, v_j + 7, 1);
      raise exception 'AUTOTEST: congé créé hors application';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Demi-journées : un jour commencé l'après-midi et fini à midi, 0 jour, pas de 0,3, dépassement : refusés.
    begin
      perform public.abs_demander_conge(v_admin, v_a, 'conges_payes', v_j + 7, v_j + 7, true, true, 0.5, null, null);
      raise exception 'AUTOTEST: après-midi → midi le même jour accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if;
      if sqlerrm not like 'Demi-journées incohérentes%' then raise exception 'AUTOTEST: message inattendu (demi-journées) : %', sqlerrm; end if;
    end;
    begin
      perform public.abs_demander_conge(v_admin, v_a, 'conges_payes', v_j + 7, v_j + 8, false, true, 0.3, null, null);
      raise exception 'AUTOTEST: 0,3 jour accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.abs_demander_conge(v_admin, v_a, 'conges_payes', v_j + 7, v_j + 8, false, true, 2, null, null);
      raise exception 'AUTOTEST: nombre de jours supérieur à la période accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.abs_demander_conge(v_admin, v_a, 'conges_payes', v_j - 3, v_j - 3, false, false, 1, null, '');
      raise exception 'AUTOTEST: demande rétroactive sans motif acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    -- J+7 matin → J+8 midi : 1,5 jour au plus.
    v_c1 := public.abs_demander_conge(v_admin, v_a, 'conges_payes', v_j + 7, v_j + 8, false, true, 1.5, null, null);
    -- Chevauchement à la demi-journée : J+8 matin refusé, J+8 après-midi accepté.
    begin
      perform public.abs_demander_conge(v_admin, v_a, 'rtt', v_j + 8, v_j + 8, false, true, 0.5, null, null);
      raise exception 'AUTOTEST: chevauchement d''une demi-journée accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    v_c2 := public.abs_demander_conge(v_admin, v_a, 'rtt', v_j + 8, v_j + 8, true, false, 0.5, null, null);
    if (select essai from public.conges where id = v_c1) is not true then
      raise exception 'AUTOTEST: congé d''une fiche d''essai non marqué essai';
    end if;

    -- Validation : prélèvement unique, deuxième appel sans effet ; validée → refusée impossible.
    v_res := public.abs_decider_conge(v_admin, v_c1, 'valider', null);
    v_res2 := public.abs_decider_conge(v_admin, v_c1, 'valider', null);
    if (select solde_conges from public.collaborateurs where id = v_a) <> 23.5 or (v_res2 ->> 'deja_decide')::boolean is not true
       or (select solde_preleve from public.conges where id = v_c1) <> 1.5
       or (select historique_soldes -> -1 ->> 'action' from public.collaborateurs where id = v_a) <> 'prelevement' then
      raise exception 'AUTOTEST: prélèvement incorrect ou doublé (% / %)', v_res, v_res2;
    end if;
    begin
      perform public.abs_decider_conge(v_admin, v_c1, 'refuser', 'Changement d''avis');
      raise exception 'AUTOTEST: congé validé refusé ensuite';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    -- RTT : droits non renseignés → validation refusée ; ajustement motivé (valeur affichée vérifiée) puis validation.
    begin
      perform public.abs_decider_conge(v_admin, v_c2, 'valider', null);
      raise exception 'AUTOTEST: RTT validée sans droits';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if;
      if sqlerrm not like 'Solde RTT insuffisant%(droits RTT non renseignés)%' then raise exception 'AUTOTEST: message inattendu (RTT) : %', sqlerrm; end if;
    end;
    begin
      perform public.abs_ajuster_solde(v_admin, v_a, 'rtt', 5, 2, 'Droits autotest');
      raise exception 'AUTOTEST: ajustement sur une valeur périmée accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.abs_ajuster_solde(v_admin, v_a, 'rtt', 0, 2, ' ');
      raise exception 'AUTOTEST: ajustement sans motif accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.abs_ajuster_solde(v_admin, v_a, 'rtt', 0, 2, 'Droits autotest');
    perform public.abs_decider_conge(v_admin, v_c2, 'valider', null);
    if (select solde_rtt from public.collaborateurs where id = v_a) <> 1.5 then
      raise exception 'AUTOTEST: solde RTT incorrect après validation';
    end if;
    -- Refus motivé ; une demande refusée ne bloque pas les dates.
    v_c3 := public.abs_demander_conge(v_admin, v_a, 'sans_solde', v_j + 10, v_j + 10, false, false, 1, null, null);
    begin
      perform public.abs_decider_conge(v_admin, v_c3, 'refuser', '');
      raise exception 'AUTOTEST: refus sans motif accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.abs_decider_conge(v_admin, v_c3, 'refuser', 'Période chargée');
    perform public.abs_demander_conge(v_admin, v_a, 'sans_solde', v_j + 10, v_j + 10, false, false, 1, null, null);
    -- Date de sortie avant une absence active : refusée. Contenu d'une demande : immuable.
    begin
      update public.collaborateurs set date_sortie = v_j + 9 where id = v_a;
      raise exception 'AUTOTEST: date de sortie avant une absence acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.abs_contexte(v_admin, 'decider_conge', null);
      update public.conges set nb_jours = 0.5 where id = v_c1;
      raise exception 'AUTOTEST: contenu d''un congé modifié';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.abs_fin_contexte();
    -- Personne ne décide pour soi (admin compris) ni n'ajuste son propre solde.
    update public.profiles set collaborateur_id = v_a where id = v_admin;
    v_c3 := public.abs_demander_conge(v_admin, v_a, 'sans_solde', v_j + 12, v_j + 12, false, false, 1, null, null);
    begin
      perform public.abs_decider_conge(v_admin, v_c3, 'valider', null);
      raise exception 'AUTOTEST: l''admin a validé son propre congé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if;
      if sqlerrm <> 'Personne ne décide de ses propres congés (administrateur compris).' then
        raise exception 'AUTOTEST: message inattendu (propres congés) : %', sqlerrm;
      end if;
    end;
    begin
      perform public.abs_ajuster_solde(v_admin, v_a, 'conges_payes', 23.5, 30, 'Pour moi');
      raise exception 'AUTOTEST: l''admin a ajusté son propre solde';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    update public.profiles set collaborateur_id = v_admin_fiche where id = v_admin;

    -- Notes de frais : dépôt simulé dans le stockage (annulé avec l'autotest). Si le stockage de Supabase refuse une
    -- écriture directe (droits ou contrôles propres au stockage), seul le refus d'un justificatif absent est vérifié ici ;
    -- le reste est vérifié par les tests locaux et le parcours en ligne.
    v_chemin := v_a || '/' || gen_random_uuid() || '.pdf';
    begin
      insert into storage.objects (bucket_id, name, metadata)
      values ('justificatifs', v_chemin, jsonb_build_object('size', 1234, 'mimetype', 'application/pdf'));
    exception when others then
      v_stockage := false;
      raise notice 'Absences : autotest des notes de frais limité (dépôt simulé refusé par le stockage : %)', sqlerrm;
    end;
    begin
      perform public.abs_creer_note(v_admin, v_a, v_j - 1, 12.5, 'repas', null, 'Déjeuner', v_a || '/' || gen_random_uuid() || '.pdf',
        'application/pdf', 1234, repeat('a', 64));
      raise exception 'AUTOTEST: note créée avec un justificatif absent du stockage';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.abs_creer_note(v_admin, v_a, v_j - 1, 12.555, 'repas', null, 'Déjeuner', v_chemin, 'application/pdf', 1234, repeat('a', 64));
      raise exception 'AUTOTEST: montant à 3 décimales accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    if v_stockage then
      begin
        perform public.abs_creer_note(v_admin, v_m, v_j - 1, 12.5, 'repas', null, 'Déjeuner', v_chemin, 'application/pdf', 1234, repeat('a', 64));
        raise exception 'AUTOTEST: justificatif d''un autre dossier accepté';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      begin
        perform public.abs_creer_note(v_admin, v_a, v_j - 1, 12.5, 'repas', null, 'Déjeuner', v_chemin, 'application/pdf', 999, repeat('a', 64));
        raise exception 'AUTOTEST: taille différente du stockage acceptée';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      begin
        perform public.abs_creer_note(v_admin, v_a, v_j - 1, 12.5, 'autre', ' ', 'Déjeuner', v_chemin, 'application/pdf', 1234, repeat('a', 64));
        raise exception 'AUTOTEST: catégorie « autre » sans précision acceptée';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      v_res := public.abs_creer_note(v_admin, v_a, v_j - 1, 12.5, 'repas', null, '  Déjeuner client  ', v_chemin, 'application/pdf', 1234, repeat('a', 64));
      v_res2 := public.abs_creer_note(v_admin, v_a, v_j - 1, 12.5, 'repas', null, '  Déjeuner client  ', v_chemin, 'application/pdf', 1234, repeat('a', 64));
      v_note := (v_res ->> 'id')::uuid;
      if v_res2 ->> 'id' <> v_res ->> 'id' or (v_res2 ->> 'deja_creee')::boolean is not true
         or (select objet <> 'Déjeuner client' or not essai from public.notes_de_frais where id = v_note) then
        raise exception 'AUTOTEST: création de note ou reprise incorrecte (% / %)', v_res, v_res2;
      end if;
      -- Modification tant que « soumise » (nouveau justificatif : l'ancien reste rattaché par l'historique).
      v_chemin2 := v_a || '/' || gen_random_uuid() || '.png';
      insert into storage.objects (bucket_id, name, metadata)
      values ('justificatifs', v_chemin2, jsonb_build_object('size', 99, 'mimetype', 'image/png'));
      perform public.abs_modifier_note(v_admin, v_note, v_j - 1, 14, 'repas', null, 'Déjeuner client', v_chemin2, 'image/png', 99, repeat('b', 64));
      if not public.abs_justificatif_rattache(v_chemin) or not public.abs_justificatif_rattache(v_chemin2) then
        raise exception 'AUTOTEST: ancien ou nouveau justificatif non rattaché';
      end if;
      perform public.abs_decider_note(v_admin, v_note, 'valider', null);
      begin
        perform public.abs_modifier_note(v_admin, v_note, v_j - 1, 15, 'repas', null, 'Déjeuner client', null, null, null, null);
        raise exception 'AUTOTEST: note validée modifiée';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      begin
        perform public.abs_contexte(v_admin, 'modifier_note', null);
        update public.notes_de_frais set justificatif_empreinte = repeat('c', 64) where id = v_note;
        raise exception 'AUTOTEST: justificatif d''une note validée modifié';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      perform public.abs_fin_contexte();
      perform public.abs_declarer_remboursement(v_admin, v_note, v_j, 'VIR-AUTOTEST');
      if (public.abs_declarer_remboursement(v_admin, v_note, v_j, 'VIR-AUTOTEST') ->> 'deja_declare')::boolean is not true then
        raise exception 'AUTOTEST: remboursement rejoué non reconnu';
      end if;
      begin
        perform public.abs_corriger_remboursement(v_admin, v_note, 'annuler', null, null, '');
        raise exception 'AUTOTEST: correction sans motif acceptée';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      perform public.abs_corriger_remboursement(v_admin, v_note, 'corriger', v_j, 'VIR-AUTOTEST-2', 'Référence erronée');
      perform public.abs_corriger_remboursement(v_admin, v_note, 'annuler', null, null, 'Remboursement déclaré par erreur');
      if (select statut <> 'validee' or rembourse_le is not null or montant <> 14
                 or (select string_agg(e ->> 'action', ',' order by o) from jsonb_array_elements(historique) with ordinality x(e, o))
                    is distinct from 'soumission,modification,validation,remboursement_declare,remboursement_corrige,remboursement_annule'
            from public.notes_de_frais where id = v_note) then
        raise exception 'AUTOTEST: suivi de la note ou historique incorrect';
      end if;
      -- Personne ne décide de sa propre note.
      update public.profiles set collaborateur_id = v_a where id = v_admin;
      v_chemin2 := v_a || '/' || gen_random_uuid() || '.jpg';
      insert into storage.objects (bucket_id, name, metadata)
      values ('justificatifs', v_chemin2, jsonb_build_object('size', 50, 'mimetype', 'image/jpeg'));
      v_res := public.abs_creer_note(v_admin, v_a, v_j, 8, 'autre', 'Parking', 'Stationnement', v_chemin2, 'image/jpeg', 50, repeat('d', 64));
      begin
        perform public.abs_decider_note(v_admin, (v_res ->> 'id')::uuid, 'valider', null);
        raise exception 'AUTOTEST: l''admin a validé sa propre note';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if;
        if sqlerrm <> 'Personne ne décide de ses propres notes de frais (administrateur compris).' then
          raise exception 'AUTOTEST: message inattendu (propres notes) : %', sqlerrm;
        end if;
      end;
      update public.profiles set collaborateur_id = v_admin_fiche where id = v_admin;
      begin
        perform public.abs_contexte(v_admin, 'modifier_note', null);
        update public.notes_de_frais set essai = false where id = v_note;
        raise exception 'AUTOTEST: drapeau essai modifié';
      exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
      perform public.abs_fin_contexte();
    end if;

    -- Nettoyage des essais : congés et notes des fiches d'essai disparaissent ; fichiers rendus pour le stockage.
    v_res := public.supprimer_essais_absences();
    if exists (select 1 from public.conges where collaborateur_id in (v_a, v_m))
       or exists (select 1 from public.notes_de_frais where collaborateur_id in (v_a, v_m))
       or (v_stockage and jsonb_array_length(v_res -> 'chemins') <> 3) then
      raise exception 'AUTOTEST: nettoyage des essais incomplet (%)', v_res;
    end if;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'Absences : autotest en échec : %', sqlerrm;
    end if;
  end;
  select md5(coalesce((select string_agg(c::text, '|' order by c.id) from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.conges c), '')
          || coalesce((select string_agg(n::text, '|' order by n.id) from public.notes_de_frais n), '')
          || coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(o.name, '|' order by o.name) from storage.objects o where o.bucket_id = 'justificatifs'), ''))
    into v_apres;
  if v_apres is distinct from v_avant then
    raise exception 'Absences : l''autotest a modifié des données réelles';
  end if;
  if coalesce(current_setting('sgi.abs_operation', true), '') <> '' or coalesce(current_setting('sgi.abs_auteur', true), '') <> ''
     or coalesce(current_setting('sgi.abs_evenement', true), '') <> '' then
    raise exception 'Absences : contexte resté actif après l''autotest';
  end if;
end
$$;
