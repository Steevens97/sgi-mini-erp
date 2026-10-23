-- Module Commercial : prospects, devis, lignes, traitement fiscal, cycle de vie, archivage PDF.
-- Évolutions approuvées A à F (+ G : avenant) — voir CLAUDE.md, section Commercial.
-- Aucune donnée existante n'est modifiée ni ne reçoit de traitement fiscal rétroactif :
-- les nouvelles colonnes sont vides pour les lignes existantes et les contraintes nouvelles
-- sont posées NOT VALID (elles s'appliquent aux écritures futures).

-- 0. Préalables -----------------------------------------------------------------------------
do $$
declare
  v_src text;
  v_nb integer;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'prochain_numero'
     and pg_get_function_identity_arguments(p.oid) = 'p_cle text, p_prefixe text';
  if v_src is null then
    raise exception 'Commercial : prochain_numero(p_cle, p_prefixe) introuvable';
  end if;
  -- Définition EXAMINÉE le 23/10/2026 (transmise par l'utilisateur, testée à l'identique sur la base
  -- d'essai) : clé = p_cle || '_' || année de current_date, ligne de compteurs verrouillée par l'UPDATE,
  -- aucune séquence → annulée avec la transaction ; numéro sur 4 chiffres. Empreinte du corps (espaces
  -- normalisés) : si la fonction a changé depuis cet examen, la migration refuse de s'appliquer.
  if md5(btrim(regexp_replace(v_src, '\s+', ' ', 'g'))) <> '72f806be71e542bd2983dd16ce16b808' then
    raise exception 'Commercial : prochain_numero diffère de la définition examinée le 23/10/2026 ; nouvel examen nécessaire';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'prochain_numero' and p.prosecdef) then
    raise exception 'Commercial : prochain_numero est devenue SECURITY DEFINER ; nouvel examen nécessaire';
  end if;
  select count(*) into v_nb from (
    select devis_id from public.projets where devis_id is not null group by devis_id having count(*) > 1) d;
  if v_nb > 0 then
    raise exception 'Commercial : % devis ont déjà plusieurs projets ; unicité impossible', v_nb;
  end if;
end
$$;

-- 1. Colonnes ---------------------------------------------------------------------------------
-- A. Traitement fiscal (devis et factures)
alter table public.devis
  add column if not exists regime_tva text,
  add column if not exists territoire_tva text,
  add column if not exists pays_tva text,
  add column if not exists taux_tva numeric(6, 3),
  add column if not exists mention_tva text,
  add column if not exists criteres_tva jsonb;
alter table public.factures
  add column if not exists regime_tva text,
  add column if not exists territoire_tva text,
  add column if not exists pays_tva text,
  add column if not exists taux_tva numeric(6, 3),
  add column if not exists mention_tva text,
  add column if not exists criteres_tva jsonb;

-- Adresse complète du destinataire (figée dans l'instantané à l'émission) et indicateur d'essai.
-- « essai » n'est modifiable par aucun jeton (pas de droit de colonne) et ne change jamais ;
-- les lignes existantes reçoivent la valeur false (ce sont des données réelles).
alter table public.prospects
  add column if not exists adresse text,
  add column if not exists code_postal text,
  add column if not exists ville text,
  add column if not exists pays text,
  add column if not exists essai boolean not null default false;
alter table public.devis
  add column if not exists essai boolean not null default false,
  -- Type de mission de SG Ingénierie : détermine les informations d'assurance exigées à l'émission.
  add column if not exists type_mission text;

-- C. Envoi déclaré ; émission ; décision du client
alter table public.devis
  add column if not exists date_envoi timestamptz,
  add column if not exists canal_envoi text,
  add column if not exists envoi_destinataire text,
  add column if not exists envoi_declare_par uuid,
  add column if not exists envoi_declare_par_nom text,
  add column if not exists envoi_declare_le timestamptz,
  add column if not exists emis_par uuid,
  add column if not exists emis_par_nom text,
  add column if not exists emis_le timestamptz,
  add column if not exists decision_par uuid,
  add column if not exists decision_par_nom text,
  add column if not exists decision_le timestamptz;

-- D/G. Liens entre devis : nouvelle version (remplace) et avenant (complète un devis accepté)
alter table public.devis
  add column if not exists remplace_devis_id uuid references public.devis(id),
  add column if not exists avenant_du_devis_id uuid references public.devis(id);

-- F. Instantané figé à l'émission et archivage du PDF
alter table public.devis
  add column if not exists instantane_emission jsonb,
  add column if not exists pdf_statut text,
  add column if not exists pdf_chemin text,
  add column if not exists pdf_empreinte text,
  add column if not exists pdf_taille bigint,
  add column if not exists pdf_archive_le timestamptz,
  add column if not exists pdf_erreur text;

-- 2. Contrôle du traitement fiscal (fonction pure, utilisée par les contraintes) -------------
create or replace function public.controle_traitement_tva(
  p_regime text, p_territoire text, p_pays text, p_taux numeric, p_mention text, p_criteres jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_ue constant text[] := array['AT','BE','BG','CY','CZ','DE','DK','EE','ES','FI','GR','HR','HU','IE',
                                'IT','LT','LU','LV','MT','NL','PL','PT','RO','SE','SI','SK'];
  v_nature text := p_criteres ->> 'nature_mission';
  v_client text := p_criteres ->> 'statut_client';
  v_standard boolean;
begin
  if p_regime is null then
    if coalesce(p_territoire, p_pays, p_mention) is not null or p_taux is not null or p_criteres is not null then
      return 'Traitement fiscal incomplet : régime manquant';
    end if;
    return null;  -- non renseigné (brouillon ou document antérieur)
  end if;

  if p_regime not in ('taxable', 'autoliquidation', 'exoneration', 'non_applicable') then
    return 'Régime de TVA inconnu';
  end if;
  if p_territoire is null or p_territoire not in ('MQ', 'GP', 'GF', 'FR', 'UE', 'AUTRE') then
    return 'Territoire fiscal inconnu';
  end if;
  if p_territoire in ('UE', 'AUTRE') then
    if p_pays is null or p_pays !~ '^[A-Z]{2}$' then
      return 'Pays obligatoire (code à 2 lettres) pour l''Union européenne ou un autre territoire';
    end if;
    if p_territoire = 'UE' and not (p_pays = any(v_ue)) then
      return 'Ce pays n''est pas un autre État membre de l''Union européenne';
    end if;
    if p_territoire = 'AUTRE' and (p_pays = any(v_ue) or p_pays = 'FR') then
      return 'Pays de l''Union européenne : choisissez le territoire UE';
    end if;
  elsif p_pays is not null then
    return 'Le pays ne se renseigne que pour l''Union européenne ou un autre territoire';
  end if;

  if p_criteres is null or jsonb_typeof(p_criteres) <> 'object' then
    return 'Critères de décision manquants (nature de la mission, statut du client)';
  end if;
  if v_nature is null or v_nature not in ('prestation_intellectuelle', 'prestation_immeuble',
                                          'travaux_immobiliers', 'autre') then
    return 'Nature de la mission manquante ou inconnue';
  end if;
  if v_client is null or v_client not in ('assujetti_france', 'assujetti_ue', 'non_assujetti',
                                          'hors_ue') then
    return 'Statut du client manquant ou inconnu';
  end if;
  if v_nature in ('prestation_immeuble', 'travaux_immobiliers')
     and coalesce(p_criteres ->> 'lieu_immeuble', '') = '' then
    return 'Lieu de l''immeuble obligatoire pour une mission se rattachant à un immeuble';
  end if;

  if p_regime = 'taxable' then
    if p_taux is null or p_taux <= 0 or p_taux >= 100 then
      return 'Taux de TVA obligatoire, supérieur à 0 et inférieur à 100 %';
    end if;
    if p_territoire = 'GF' then
      return 'TVA non applicable en Guyane : choisissez le régime « non applicable »';
    end if;
    v_standard := (p_territoire in ('MQ', 'GP') and p_taux = 8.5) or (p_territoire = 'FR' and p_taux = 20);
    if not v_standard and length(coalesce(p_criteres ->> 'justification_taux', '')) < 10 then
      return 'Taux autre que le taux normal du territoire : justification obligatoire (10 caractères minimum)';
    end if;
  else
    if p_taux is not null then
      return 'Aucun taux pour un régime sans TVA facturée';
    end if;
    if length(coalesce(p_mention, '')) < 5 then
      return 'Mention justificative obligatoire pour ce régime';
    end if;
    if p_regime = 'autoliquidation' and coalesce(p_criteres ->> 'numero_tva_client', '') = '' then
      return 'Autoliquidation : numéro de TVA du client obligatoire';
    end if;
  end if;
  return null;
end
$$;

create or replace function public.montant_tva(p_regime text, p_taux numeric, p_total_ht numeric)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case when p_regime = 'taxable' then round(p_total_ht * p_taux / 100, 2) else 0 end;
$$;

-- 3. Contraintes (NOT VALID : n'affectent pas les données existantes) ---------------------------
do $$
declare
  v_contrainte record;
begin
  -- Remplacement de la liste des statuts de devis (balayage des anciennes contraintes sur statut).
  for v_contrainte in
    select c.conname
      from pg_constraint c
     where c.conrelid = 'public.devis'::regclass and c.contype = 'c'
       and pg_get_constraintdef(c.oid) ilike '%statut%'
  loop
    execute format('alter table public.devis drop constraint %I', v_contrainte.conname);
  end loop;

  for v_contrainte in
    select conname, conrelid::regclass::text as table_nom from pg_constraint
     where conrelid in ('public.devis'::regclass, 'public.factures'::regclass, 'public.devis_lignes'::regclass)
       and conname in ('devis_statut_liste', 'devis_traitement_tva', 'factures_traitement_tva',
                       'devis_totaux_coherents', 'devis_numero_selon_statut', 'devis_canal_envoi_liste',
                       'devis_pdf_statut_liste', 'devis_un_seul_lien', 'devis_pas_lien_soi_meme',
                       'devis_type_mission_liste')
  loop
    execute format('alter table %s drop constraint %I', v_contrainte.table_nom, v_contrainte.conname);
  end loop;
end
$$;

alter table public.devis add constraint devis_statut_liste
  check (statut in ('brouillon', 'emis', 'envoye', 'accepte', 'refuse', 'remplace'));
-- Les contrôles fiscaux complets passent par des déclencheurs (5b, 5c, 5f) : une contrainte qui
-- appellerait une fonction obligerait à la rendre exécutable par les comptes connectés.
alter table public.devis add constraint devis_totaux_coherents
  check (total_ttc = total_ht + tva
         and (regime_tva is null
              or tva = case when regime_tva = 'taxable' then round(total_ht * taux_tva / 100, 2) else 0 end))
  not valid;
alter table public.devis add constraint devis_numero_selon_statut
  check ((statut = 'brouillon') = (numero is null)) not valid;
alter table public.devis add constraint devis_type_mission_liste
  check (type_mission is null or type_mission in ('conseil', 'amo', 'moex', 'opc', 'donnees', 'drone', 'autre'));
alter table public.devis add constraint devis_canal_envoi_liste
  check (canal_envoi is null or canal_envoi in ('email', 'main_propre', 'courrier', 'plateforme', 'autre'));
alter table public.devis add constraint devis_pdf_statut_liste
  check (pdf_statut is null or pdf_statut in ('a_generer', 'disponible', 'echec'));
alter table public.devis add constraint devis_un_seul_lien
  check (remplace_devis_id is null or avenant_du_devis_id is null);
alter table public.devis add constraint devis_pas_lien_soi_meme
  check (remplace_devis_id is distinct from id and avenant_du_devis_id is distinct from id);

create unique index if not exists devis_numero_unique on public.devis (numero) where numero is not null;
create unique index if not exists devis_un_seul_successeur on public.devis (remplace_devis_id)
  where remplace_devis_id is not null;
-- E. Un seul projet par devis
create unique index if not exists projets_un_par_devis on public.projets (devis_id) where devis_id is not null;

-- 4. Outils internes ---------------------------------------------------------------------------
-- Auteur d'une action commerciale (appelée par les fonctions serveur) : admin ou manager actif.
create or replace function public.verifier_auteur_commercial(p_auteur uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_nom text;
begin
  select coalesce(nullif(p.nom, ''), p.email) into v_nom
    from public.profiles p join auth.users u on u.id = p.id
   where p.id = p_auteur and p.role in ('admin', 'manager')
     and (u.banned_until is null or u.banned_until <= now())
     and coalesce((u.raw_app_meta_data ->> 'doit_changer_mot_de_passe')::boolean, false) = false;
  if v_nom is null then
    raise exception 'Action commerciale réservée à un administrateur ou manager actif';
  end if;
  return v_nom;
end
$$;

-- Appel fait avec un jeton utilisateur (application ou API), par opposition à la clé secrète
-- ou au tableau de bord. Lit le rôle sous lequel la requête s'exécute (posé par l'API, inchangé
-- dans une fonction SECURITY DEFINER), jamais le contenu du jeton.
create or replace function public.appel_utilisateur()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('role', true), '') in ('authenticated', 'anon');
$$;

-- Coordonnées de l'émetteur (SG Ingénierie) : champs indispensables, sinon émission bloquée.
-- Assurance : exigée selon la mission. L'application transmet « obligation_assurance » (obligatoire ou
-- non_requise), décidée par l'utilisateur pour chaque type de mission ; « a_confirmer » bloque.
-- La maîtrise d'œuvre d'exécution (MOEx) relève de l'assurance décennale obligatoire (C. assur.
-- L241-1, C. civ. 1792-1) : la base l'impose. Aucune couverture ni attestation n'est inventée.
create or replace function public.controle_emetteur(p_emetteur jsonb, p_type_mission text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_manquants text[] := '{}';
  v_cle text;
  v_obligation text := p_emetteur ->> 'obligation_assurance';
begin
  if p_emetteur is null or jsonb_typeof(p_emetteur) <> 'object' then
    return 'coordonnées de l''émetteur absentes';
  end if;
  if p_type_mission is null then
    return 'type de mission non renseigné';
  end if;
  foreach v_cle in array array['raison_sociale', 'forme_juridique', 'adresse', 'code_postal', 'ville', 'siret',
                               'immatriculation', 'tva_intracom', 'validite_jours'] loop
    if coalesce(trim(p_emetteur ->> v_cle), '') = '' then
      v_manquants := v_manquants || v_cle;
    end if;
  end loop;
  if upper(coalesce(p_emetteur ->> 'forme_juridique', '')) in ('SARL', 'EURL', 'SAS', 'SASU', 'SA', 'SNC',
                                                               'SELARL', 'SELAS')
     and coalesce(trim(p_emetteur ->> 'capital_social'), '') = '' then
    v_manquants := v_manquants || 'capital_social'::text;
  end if;
  if array_length(v_manquants, 1) > 0 then
    return 'coordonnées de SG Ingénierie incomplètes : ' || array_to_string(v_manquants, ', ');
  end if;
  if replace(p_emetteur ->> 'siret', ' ', '') !~ '^[0-9]{14}$' then
    return 'SIRET de l''émetteur invalide (14 chiffres)';
  end if;
  if (p_emetteur ->> 'validite_jours') !~ '^[1-9][0-9]*$' then
    return 'durée de validité du devis invalide (nombre de jours)';
  end if;

  if v_obligation is null or v_obligation not in ('obligatoire', 'non_requise') then
    return 'obligation d''assurance non déterminée pour ce type de mission (à confirmer avec votre assureur)';
  end if;
  if p_type_mission = 'moex' and v_obligation <> 'obligatoire' then
    return 'maîtrise d''œuvre d''exécution : assurance décennale obligatoire';
  end if;
  if v_obligation = 'obligatoire' then
    foreach v_cle in array array['assurance_assureur', 'assurance_contrat', 'assurance_couverture'] loop
      if coalesce(trim(p_emetteur ->> v_cle), '') = '' then
        v_manquants := v_manquants || v_cle;
      end if;
    end loop;
    if array_length(v_manquants, 1) > 0 then
      return 'assurance obligatoire pour cette mission : ' || array_to_string(v_manquants, ', ') || ' manquant(s)';
    end if;
  end if;
  return null;
end
$$;

-- Destinataire : nom (ou société) et adresse postale complète, obligatoires avant l'émission.
create or replace function public.controle_destinataire(p_prospect_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.prospects;
  v_manquants text[] := '{}';
begin
  select * into v from public.prospects where id = p_prospect_id;
  if coalesce(trim(v.societe), '') = '' and coalesce(trim(v.nom), '') = '' then
    v_manquants := v_manquants || 'nom ou société'::text;
  end if;
  if coalesce(trim(v.adresse), '') = '' then v_manquants := v_manquants || 'adresse'::text; end if;
  if coalesce(trim(v.ville), '') = '' then v_manquants := v_manquants || 'ville'::text; end if;
  if coalesce(trim(v.pays), '') = '' then v_manquants := v_manquants || 'pays'::text; end if;
  if v.pays in ('FR', 'MQ', 'GP', 'GF', 'RE', 'YT') and coalesce(trim(v.code_postal), '') = '' then
    v_manquants := v_manquants || 'code postal'::text;
  end if;
  if array_length(v_manquants, 1) > 0 then
    return 'adresse du destinataire incomplète : ' || array_to_string(v_manquants, ', ');
  end if;
  return null;
end
$$;

-- Instantané de tout ce qui est imprimé, construit par la base au moment de l'émission.
create or replace function public.construire_instantane_devis(p_devis public.devis)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'version', 1,
    'essai', p_devis.essai,
    'type_mission', p_devis.type_mission,
    'emetteur', p_devis.instantane_emission -> 'emetteur',
    'gabarit', p_devis.instantane_emission ->> 'gabarit',
    'numero', p_devis.numero,
    'date_emission', p_devis.date_emission,
    'emis_par_nom', p_devis.emis_par_nom,
    'destinataire', (
      select jsonb_build_object(
        'prospect', jsonb_build_object('nom', pr.nom, 'societe', pr.societe, 'email', pr.email,
                                       'telephone', pr.telephone, 'adresse', pr.adresse,
                                       'code_postal', pr.code_postal, 'ville', pr.ville, 'pays', pr.pays),
        'client', case when c.id is null then null else
                  jsonb_build_object('nom', c.nom, 'adresse', c.adresse, 'email', c.email_contact,
                                     'telephone', c.telephone) end)
        from public.prospects pr left join public.clients c on c.id = pr.client_id
       where pr.id = p_devis.prospect_id),
    'lignes', coalesce((
      select jsonb_agg(jsonb_build_object('designation', l.designation, 'quantite', l.quantite,
                                          'prix_unitaire', l.prix_unitaire, 'montant_ht', l.montant_ht)
                       order by l.created_at, l.id)
        from public.devis_lignes l where l.devis_id = p_devis.id), '[]'::jsonb),
    'totaux', jsonb_build_object('total_ht', p_devis.total_ht, 'tva', p_devis.tva,
                                 'total_ttc', p_devis.total_ttc),
    'tva', jsonb_build_object('regime', p_devis.regime_tva, 'territoire', p_devis.territoire_tva,
                              'pays', p_devis.pays_tva, 'taux', p_devis.taux_tva,
                              'mention', p_devis.mention_tva, 'criteres', p_devis.criteres_tva),
    'remplace', (select d.numero from public.devis d where d.id = p_devis.remplace_devis_id),
    'avenant_de', (select d.numero from public.devis d where d.id = p_devis.avenant_du_devis_id));
$$;

-- Attribution d'un numéro : SEUL point d'appel de prochain_numero, uniquement depuis les opérations
-- transactionnelles prévues (émission). Pendant l'appel, fuseau America/Martinique (clause SET : rétabli
-- à la sortie de la fonction, la connexion n'est pas modifiée) → l'année du numéro est celle de la
-- Martinique. Blocage explicite avant le 10 000e numéro d'une année (prochain_numero tronque à 4 chiffres).
create or replace function public.attribuer_numero(p_cle text, p_prefixe text)
returns text
language plpgsql
set search_path = public
set timezone = 'America/Martinique'
as $$
declare
  v_cle text;
  v_valeur integer;
begin
  if p_cle not in ('devis', 'essai_devis') then
    raise exception 'Numérotation : clé « % » non prévue', p_cle;
  end if;
  v_cle := p_cle || '_' || to_char(current_date, 'YYYY');  -- même règle que prochain_numero
  -- Verrou de la ligne du compteur : le contrôle de limite et l'incrément ne peuvent pas être doublés.
  select valeur into v_valeur from public.compteurs where cle = v_cle for update;
  if coalesce(v_valeur, 0) >= 9999 then
    raise exception 'Numérotation impossible : la limite de 9 999 documents « % » pour l''année % est atteinte. Aucun numéro n''a été attribué. Contactez l''administrateur.',
      p_prefixe, to_char(current_date, 'YYYY');
  end if;
  return public.prochain_numero(p_cle, p_prefixe);
end
$$;

-- Cumul d'une mission : devis initial + avenants acceptés + l'avenant examiné ne peut pas être négatif.
-- VOLATILE (et non STABLE) : appelée après le verrou du devis initial, elle doit voir les
-- acceptations validées entre-temps par une autre transaction.
create or replace function public.controle_cumul_avenants(p_initial uuid, p_avenant uuid, p_total_avenant numeric)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_cumul numeric;
begin
  select d.total_ht
         + coalesce((select sum(a.total_ht) from public.devis a
                      where a.avenant_du_devis_id = p_initial and a.statut = 'accepte' and a.id <> p_avenant), 0)
         + p_total_avenant
    into v_cumul
    from public.devis d where d.id = p_initial;
  if v_cumul < 0 then
    return 'le total de la mission (devis initial + avenants acceptés + cet avenant) deviendrait négatif ('
           || v_cumul || ' € HT)';
  end if;
  return null;
end
$$;

-- 5. Déclencheurs ---------------------------------------------------------------------------------
-- 5a. Lignes : seulement sur un brouillon ; montant recalculé ; totaux du devis recalculés.
create or replace function public.devis_lignes_avant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_statut text;
  v_avenant uuid;
  v_essai boolean;
  v_devis uuid := case when tg_op = 'DELETE' then old.devis_id else new.devis_id end;
begin
  if tg_op = 'UPDATE' and new.devis_id is distinct from old.devis_id then
    raise exception 'Une ligne ne peut pas changer de devis';
  end if;
  select statut, avenant_du_devis_id, essai into v_statut, v_avenant, v_essai
    from public.devis where id = v_devis for update;
  if not found then
    if tg_op = 'DELETE' then return old; end if;  -- suppression en cascade du devis
    raise exception 'Devis introuvable';
  end if;
  if v_essai and public.appel_utilisateur() then
    raise exception 'Devis d''essai : modifiable uniquement par les essais autorisés (clé secrète)';
  end if;
  if v_statut <> 'brouillon' then
    raise exception 'Devis % : les lignes ne sont modifiables qu''au stade brouillon', v_statut;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if coalesce(trim(new.designation), '') = '' then
    raise exception 'Désignation obligatoire';
  end if;
  if new.quantite is null or new.quantite = 0 or (new.quantite < 0 and v_avenant is null) then
    raise exception 'Quantité non nulle obligatoire (négative seulement dans un avenant)';
  end if;
  if new.prix_unitaire is null or new.prix_unitaire < 0 then
    raise exception 'Prix unitaire positif ou nul obligatoire';
  end if;
  new.montant_ht := round(new.quantite * new.prix_unitaire, 2);
  return new;
end
$$;

create or replace function public.devis_lignes_apres()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Le déclencheur du devis recalcule ses totaux à chaque modification d'un brouillon.
  update public.devis set total_ht = total_ht
   where id = case when tg_op = 'DELETE' then old.devis_id else new.devis_id end
     and statut = 'brouillon';
  return null;
end
$$;

drop trigger if exists devis_lignes_avant on public.devis_lignes;
create trigger devis_lignes_avant before insert or update or delete on public.devis_lignes
  for each row execute function public.devis_lignes_avant();
drop trigger if exists devis_lignes_apres on public.devis_lignes;
create trigger devis_lignes_apres after insert or update or delete on public.devis_lignes
  for each row execute function public.devis_lignes_apres();

-- 5b. Devis : création toujours en brouillon, liens contrôlés.
create or replace function public.devis_avant_creation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source public.devis;
  v_erreur text;
begin
  if new.statut is distinct from 'brouillon' or new.numero is not null then
    raise exception 'Un devis est toujours créé en brouillon, sans numéro';
  end if;
  -- Le caractère « essai » vient du prospect (posé par une fonction réservée), jamais de la saisie.
  select essai into new.essai from public.prospects where id = new.prospect_id;
  if new.essai is null then
    raise exception 'Prospect introuvable';
  end if;
  if new.essai and public.appel_utilisateur() then
    raise exception 'Devis d''essai : création réservée aux essais autorisés (clé secrète)';
  end if;
  if coalesce(new.date_envoi::text, new.canal_envoi, new.envoi_destinataire, new.envoi_declare_par::text,
              new.envoi_declare_par_nom, new.envoi_declare_le::text, new.emis_par::text, new.emis_par_nom,
              new.emis_le::text, new.decision_par::text, new.decision_par_nom, new.decision_le::text,
              new.instantane_emission::text, new.pdf_statut, new.pdf_chemin, new.pdf_empreinte,
              new.pdf_taille::text, new.pdf_archive_le::text, new.pdf_erreur) is not null then
    raise exception 'Champs d''émission, d''envoi, de décision ou de PDF interdits à la création';
  end if;
  if new.remplace_devis_id is not null then
    select * into v_source from public.devis where id = new.remplace_devis_id for update;
    if v_source.statut = 'accepte' then
      raise exception 'Un devis accepté ne peut pas être remplacé : créez un avenant';
    end if;
    if v_source.statut not in ('emis', 'envoye') then
      raise exception 'Seul un devis émis ou envoyé peut recevoir une nouvelle version';
    end if;
    if v_source.prospect_id <> new.prospect_id then
      raise exception 'Une nouvelle version concerne le même prospect';
    end if;
  end if;
  if new.avenant_du_devis_id is not null then
    select * into v_source from public.devis where id = new.avenant_du_devis_id for update;
    if v_source.statut <> 'accepte' or v_source.avenant_du_devis_id is not null then
      raise exception 'Un avenant complète un devis initial accepté';
    end if;
    if v_source.prospect_id <> new.prospect_id then
      raise exception 'Un avenant concerne le même prospect';
    end if;
  end if;
  v_erreur := public.controle_traitement_tva(new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva,
                                             new.mention_tva, new.criteres_tva);
  if v_erreur is not null then
    raise exception 'TVA : %', v_erreur;
  end if;
  new.total_ht := 0;
  new.tva := 0;
  new.total_ttc := 0;
  return new;
end
$$;

drop trigger if exists devis_avant_creation on public.devis;
create trigger devis_avant_creation before insert on public.devis
  for each row execute function public.devis_avant_creation();

-- 5c. Devis : cycle de vie (s'applique à TOUT client : application, API, tableau de bord).
create or replace function public.devis_avant_modification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_essai boolean;
  v_annee text;
  v_nb integer;
  v_erreur text;
  v_source public.devis;
begin
  if new.essai is distinct from old.essai then
    raise exception 'Le caractère « essai » d''un devis ne change jamais';
  end if;
  if old.essai and public.appel_utilisateur() then
    raise exception 'Devis d''essai : modifiable uniquement par les essais autorisés (clé secrète)';
  end if;
  -- Contenu figé hors brouillon.
  if old.statut <> 'brouillon' and
     (new.id, new.prospect_id, new.numero, new.date_emission, new.total_ht, new.tva, new.total_ttc,
      new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva, new.mention_tva, new.criteres_tva,
      new.instantane_emission, new.emis_par, new.emis_par_nom, new.emis_le,
      new.remplace_devis_id, new.avenant_du_devis_id, new.created_at, new.type_mission)
     is distinct from
     (old.id, old.prospect_id, old.numero, old.date_emission, old.total_ht, old.tva, old.total_ttc,
      old.regime_tva, old.territoire_tva, old.pays_tva, old.taux_tva, old.mention_tva, old.criteres_tva,
      old.instantane_emission, old.emis_par, old.emis_par_nom, old.emis_le,
      old.remplace_devis_id, old.avenant_du_devis_id, old.created_at, old.type_mission) then
    raise exception 'Devis % (%) : contenu figé depuis l''émission', old.numero, old.statut;
  end if;

  -- Liens de version et d'avenant : fixés à la création.
  if (new.remplace_devis_id, new.avenant_du_devis_id) is distinct from (old.remplace_devis_id, old.avenant_du_devis_id) then
    raise exception 'Les liens de version et d''avenant ne se modifient pas';
  end if;

  -- Champs d'envoi : posés uniquement au passage émis → envoyé.
  if not (old.statut = 'emis' and new.statut = 'envoye') and
     (new.date_envoi, new.canal_envoi, new.envoi_destinataire, new.envoi_declare_par, new.envoi_declare_par_nom,
      new.envoi_declare_le) is distinct from
     (old.date_envoi, old.canal_envoi, old.envoi_destinataire, old.envoi_declare_par, old.envoi_declare_par_nom,
      old.envoi_declare_le) then
    raise exception 'Les informations d''envoi ne se posent qu''en déclarant l''envoi d''un devis émis';
  end if;
  -- Champs de décision : posés uniquement à l'acceptation ou au refus.
  if not (old.statut = 'envoye' and new.statut in ('accepte', 'refuse')) and
     (new.decision_par, new.decision_par_nom, new.decision_le) is distinct from
     (old.decision_par, old.decision_par_nom, old.decision_le) then
    raise exception 'Les informations de décision ne se posent qu''à l''acceptation ou au refus';
  end if;
  -- PDF : rien en brouillon ; une fois disponible, plus jamais modifié.
  if (new.pdf_statut, new.pdf_chemin, new.pdf_empreinte, new.pdf_taille, new.pdf_archive_le, new.pdf_erreur)
     is distinct from
     (old.pdf_statut, old.pdf_chemin, old.pdf_empreinte, old.pdf_taille, old.pdf_archive_le, old.pdf_erreur) then
    if old.statut = 'brouillon' and not (new.statut = 'emis') then
      raise exception 'Pas de PDF archivé pour un brouillon';
    end if;
    if old.pdf_statut = 'disponible' then
      raise exception 'PDF archivé : il ne peut plus être remplacé';
    end if;
    if new.pdf_statut = 'disponible' and (new.pdf_chemin is distinct from old.id || '/' || old.numero || '.pdf'
        or coalesce(new.pdf_empreinte, '') !~ '^[0-9a-f]{64}$' or coalesce(new.pdf_taille, 0) <= 0) then
      raise exception 'PDF disponible : chemin, empreinte SHA-256 et taille obligatoires';
    end if;
  end if;

  if new.statut = old.statut then
    if new.statut = 'brouillon' then
      if new.numero is not null or new.emis_le is not null or new.instantane_emission is not null then
        raise exception 'Un brouillon n''a ni numéro ni émission';
      end if;
      v_erreur := public.controle_traitement_tva(new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva,
                                                 new.mention_tva, new.criteres_tva);
      if v_erreur is not null then
        raise exception 'TVA : %', v_erreur;
      end if;
      -- Recalcul systématique des totaux d'un brouillon.
      select coalesce(sum(montant_ht), 0) into new.total_ht from public.devis_lignes where devis_id = new.id;
      new.tva := public.montant_tva(new.regime_tva, new.taux_tva, new.total_ht);
      new.total_ttc := new.total_ht + new.tva;
    end if;
    return new;
  end if;

  -- Transitions autorisées.
  if old.statut = 'brouillon' and new.statut = 'emis' then
    if old.numero is not null or new.numero is not null then
      raise exception 'Le numéro est attribué par la base à l''émission, jamais saisi';
    end if;
    if new.regime_tva is null then
      raise exception 'Émission impossible : traitement fiscal non renseigné';
    end if;
    v_erreur := public.controle_traitement_tva(new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva,
                                               new.mention_tva, new.criteres_tva);
    if v_erreur is not null then
      raise exception 'Émission impossible : %', v_erreur;
    end if;
    select count(*) into v_nb from public.devis_lignes where devis_id = new.id;
    if v_nb = 0 then
      raise exception 'Émission impossible : aucune ligne';
    end if;
    if new.instantane_emission is null or coalesce(new.instantane_emission ->> 'gabarit', '') = '' then
      raise exception 'Émission impossible : version du gabarit obligatoire';
    end if;
    v_erreur := public.controle_emetteur(new.instantane_emission -> 'emetteur', new.type_mission);
    if v_erreur is not null then
      raise exception 'Émission impossible : %', v_erreur;
    end if;
    if not new.essai and (new.instantane_emission -> 'emetteur')::text ilike '%[DÉMO]%' then
      raise exception 'Émission impossible : coordonnées de démonstration interdites sur un devis réel';
    end if;
    v_erreur := public.controle_destinataire(new.prospect_id);
    if v_erreur is not null then
      raise exception 'Émission impossible : %', v_erreur;
    end if;
    if new.remplace_devis_id is not null then
      select * into v_source from public.devis where id = new.remplace_devis_id for update;
      if v_source.statut not in ('emis', 'envoye') then
        raise exception 'Le devis remplacé n''est plus émis ou envoyé (statut : %)', v_source.statut;
      end if;
    end if;
    select coalesce(sum(montant_ht), 0) into new.total_ht from public.devis_lignes where devis_id = new.id;
    new.tva := public.montant_tva(new.regime_tva, new.taux_tva, new.total_ht);
    new.total_ttc := new.total_ht + new.tva;

    if new.avenant_du_devis_id is not null then
      select * into v_source from public.devis where id = new.avenant_du_devis_id;
      if v_source.statut <> 'accepte' then
        raise exception 'Le devis complété par cet avenant n''est plus accepté';
      end if;
      if not exists (select 1 from public.projets where devis_id = v_source.id) then
        raise exception 'Le devis accepté n''a pas de projet : avenant impossible';
      end if;
      perform 1 from public.devis where id = v_source.id for update;  -- sérialise les avenants d'une mission
      v_erreur := public.controle_cumul_avenants(v_source.id, new.id, new.total_ht);
      if v_erreur is not null then
        raise exception 'Émission impossible : %', v_erreur;
      end if;
    elsif new.total_ht < 0 then
      raise exception 'Émission impossible : seul un avenant peut avoir un total négatif';
    end if;

    -- Numéro, exclusivement par prochain_numero (via attribuer_numero : heure de Martinique,
    -- limite de 9 999). Devis réel : clé « devis », préfixe « DEV ». Devis d'essai (indicateur non
    -- modifiable) : clé « essai_devis », préfixe « ESSAI-DEV » — compteur distinct du compteur réel.
    if new.essai then
      new.numero := public.attribuer_numero('essai_devis', 'ESSAI-DEV');
    else
      new.numero := public.attribuer_numero('devis', 'DEV');
    end if;
    new.date_emission := (now() at time zone 'America/Martinique')::date;
    new.emis_le := now();
    if new.emis_par is null then
      new.emis_par_nom := 'Hors application (' || session_user || ')';
    end if;
    new.instantane_emission := public.construire_instantane_devis(new);
    new.pdf_statut := 'a_generer';
    return new;
  end if;

  if old.statut = 'emis' and new.statut = 'envoye' then
    if old.pdf_statut is distinct from 'disponible' then
      raise exception 'Envoi impossible : le PDF archivé n''est pas disponible';
    end if;
    if new.date_envoi is null or new.canal_envoi is null then
      raise exception 'Envoi : date et canal obligatoires';
    end if;
    if new.date_envoi::date < old.date_emission or new.date_envoi > now() + interval '1 hour' then
      raise exception 'Envoi : date antérieure à l''émission ou dans le futur';
    end if;
    new.envoi_declare_le := now();
    if new.envoi_declare_par is null then
      new.envoi_declare_par_nom := 'Hors application (' || session_user || ')';
    end if;
    return new;
  end if;

  if old.statut = 'envoye' and new.statut in ('accepte', 'refuse') then
    if new.statut = 'accepte' and new.avenant_du_devis_id is not null then
      -- Verrou du devis initial : deux acceptations simultanées d'avenants de la même mission
      -- s'attendent ; la seconde voit la première et le cumul est vérifié sur l'état réel.
      perform 1 from public.devis where id = new.avenant_du_devis_id for update;
      v_erreur := public.controle_cumul_avenants(new.avenant_du_devis_id, new.id, new.total_ht);
      if v_erreur is not null then
        raise exception 'Acceptation impossible : %', v_erreur;
      end if;
    end if;
    new.decision_le := now();
    if new.decision_par is null then
      new.decision_par_nom := 'Hors application (' || session_user || ')';
    end if;
    return new;
  end if;

  if old.statut in ('emis', 'envoye') and new.statut = 'remplace' then
    select count(*) into v_nb from public.devis where remplace_devis_id = old.id and statut = 'emis';
    if v_nb = 0 then
      raise exception 'Un devis ne passe à « remplacé » qu''à l''émission de sa nouvelle version';
    end if;
    return new;
  end if;

  if old.statut = 'accepte' and new.statut = 'remplace' then
    raise exception 'Un devis accepté ne peut pas être remplacé : créez un avenant';
  end if;
  raise exception 'Passage de « % » à « % » interdit', old.statut, new.statut;
end
$$;

drop trigger if exists devis_avant_modification on public.devis;
create trigger devis_avant_modification before update on public.devis
  for each row execute function public.devis_avant_modification();

-- 5d. Devis : conséquences (version remplacée, prospect, acceptation → client + projet).
create or replace function public.devis_apres_modification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prospect public.prospects;
  v_client uuid;
begin
  if old.statut = 'brouillon' and new.statut = 'emis' and new.remplace_devis_id is not null then
    update public.devis set statut = 'remplace' where id = new.remplace_devis_id;
  end if;

  if old.statut = 'emis' and new.statut = 'envoye' then
    update public.prospects set statut = 'devis_envoye'
     where id = new.prospect_id and statut in ('contacte', 'perdu');
  end if;

  if old.statut <> 'accepte' and new.statut = 'accepte' then
    -- Verrou du prospect : deux acceptations simultanées s'attendent (pas de client en double).
    select * into v_prospect from public.prospects where id = new.prospect_id for update;
    if new.avenant_du_devis_id is null then
      v_client := v_prospect.client_id;
      if v_client is null then
        insert into public.clients (nom, email_contact, telephone, adresse)
        values (case when new.essai then '[ESSAI] ' else '' end
                  || coalesce(nullif(trim(v_prospect.societe), ''), v_prospect.nom),
                v_prospect.email, v_prospect.telephone,
                concat_ws(E'\n', v_prospect.adresse,
                          nullif(concat_ws(' ', v_prospect.code_postal, v_prospect.ville), ''), v_prospect.pays))
        returning id into v_client;
        update public.prospects set client_id = v_client where id = v_prospect.id;
      end if;
      insert into public.projets (nom, client_id, devis_id, statut)
      values (case when new.essai then '[ESSAI] ' else '' end || 'Projet ' || new.numero, v_client, new.id, 'en_cours')
      on conflict (devis_id) where devis_id is not null do nothing;
    end if;
    update public.prospects set statut = 'gagne' where id = v_prospect.id and statut <> 'gagne';
  end if;
  return null;
end
$$;

drop trigger if exists devis_apres_modification on public.devis;
create trigger devis_apres_modification after update on public.devis
  for each row execute function public.devis_apres_modification();

create or replace function public.devis_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Exception unique : nettoyage des devis d'ESSAI par la clé secrète (supprimer_essais_commercial).
  if old.essai and not public.appel_utilisateur() then
    return old;
  end if;
  if old.statut <> 'brouillon' then
    raise exception 'Seul un brouillon peut être supprimé (devis % : %)', old.numero, old.statut;
  end if;
  return old;
end
$$;

drop trigger if exists devis_avant_suppression on public.devis;
create trigger devis_avant_suppression before delete on public.devis
  for each row execute function public.devis_avant_suppression();

-- 5e. Prospects : « devis envoyé » et « gagné » découlent des devis, jamais d'un choix manuel.
create or replace function public.prospects_avant_ecriture()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_accepte boolean;
  v_envoye boolean;
begin
  if new.pays is not null and new.pays !~ '^[A-Z]{2}$' then
    raise exception 'Pays du prospect : code à 2 lettres (FR, MQ, GP, GF, DE…)';
  end if;
  if tg_op = 'INSERT' then
    if new.statut not in ('contacte', 'perdu') then
      raise exception 'Un prospect est créé « contacté » ou « perdu » ; les autres statuts découlent des devis';
    end if;
    if new.essai and (public.appel_utilisateur() or new.client_id is not null) then
      raise exception 'Prospect d''essai : création réservée aux essais autorisés, sans client existant';
    end if;
    return new;
  end if;

  if new.essai is distinct from old.essai then
    raise exception 'Le caractère « essai » d''un prospect ne change jamais';
  end if;
  if old.essai and public.appel_utilisateur() then
    raise exception 'Prospect d''essai : modifiable uniquement par les essais autorisés (clé secrète)';
  end if;

  select exists (select 1 from public.devis where prospect_id = new.id and statut = 'accepte'),
         exists (select 1 from public.devis where prospect_id = new.id and statut = 'envoye')
    into v_accepte, v_envoye;

  if new.client_id is distinct from old.client_id then
    if old.client_id is not null then
      raise exception 'Le client lié à un prospect ne se change pas';
    end if;
    if v_accepte and pg_trigger_depth() < 2 then
      raise exception 'Le client est rattaché automatiquement à l''acceptation du devis';
    end if;
  end if;

  if new.statut is distinct from old.statut then
    if new.statut = 'gagne' and not v_accepte then
      raise exception '« Gagné » découle de l''acceptation d''un devis : acceptez le devis';
    end if;
    if new.statut = 'devis_envoye' and (not v_envoye or v_accepte) then
      raise exception '« Devis envoyé » découle de la déclaration d''envoi d''un devis';
    end if;
    if new.statut in ('perdu', 'contacte') and v_accepte then
      raise exception 'Un devis de ce prospect est accepté : statut « gagné » obligatoire';
    end if;
    if new.statut = 'contacte' and v_envoye then
      raise exception 'Un devis envoyé est en attente : statut « devis envoyé » ou « perdu »';
    end if;
  end if;
  return new;
end
$$;

drop trigger if exists prospects_avant_ecriture on public.prospects;
create trigger prospects_avant_ecriture before insert or update on public.prospects
  for each row execute function public.prospects_avant_ecriture();

-- 5f. Factures : même contrôle du traitement fiscal (le reste viendra avec le module Finance).
create or replace function public.factures_controle_tva()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_erreur text := public.controle_traitement_tva(new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva,
                                                  new.mention_tva, new.criteres_tva);
begin
  if v_erreur is not null then
    raise exception 'TVA : %', v_erreur;
  end if;
  return new;
end
$$;

drop trigger if exists factures_controle_tva on public.factures;
create trigger factures_controle_tva
  before insert or update of regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, criteres_tva
  on public.factures for each row execute function public.factures_controle_tva();

-- 6. Fonctions serveur (clé secrète uniquement, après vérification des droits dans l'action) -----
create or replace function public.emettre_devis(p_devis_id uuid, p_auteur uuid, p_emetteur jsonb, p_gabarit text)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_commercial(p_auteur);
  v_devis public.devis;
begin
  select * into v_devis from public.devis where id = p_devis_id for update;
  if not found then
    raise exception 'Devis introuvable';
  end if;
  if v_devis.statut <> 'brouillon' then
    return v_devis.numero;  -- nouvel essai : aucun numéro consommé
  end if;
  update public.devis
     set statut = 'emis', emis_par = p_auteur, emis_par_nom = v_nom,
         instantane_emission = jsonb_build_object('emetteur', p_emetteur, 'gabarit', p_gabarit)
   where id = p_devis_id
  returning numero into v_devis.numero;
  return v_devis.numero;
end
$$;

create or replace function public.enregistrer_pdf_devis(p_devis_id uuid, p_chemin text, p_empreinte text, p_taille bigint)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_devis public.devis;
begin
  select * into v_devis from public.devis where id = p_devis_id for update;
  if not found or v_devis.statut = 'brouillon' then
    raise exception 'Devis introuvable ou non émis';
  end if;
  if v_devis.pdf_statut = 'disponible' then
    if v_devis.pdf_empreinte = p_empreinte and v_devis.pdf_chemin = p_chemin then
      return;
    end if;
    raise exception 'Un PDF différent est déjà archivé pour ce devis';
  end if;
  -- Le fichier doit réellement exister dans le bucket privé, avec la taille annoncée.
  if not exists (select 1 from storage.objects o
                  where o.bucket_id = 'devis' and o.name = p_chemin
                    and (o.metadata ->> 'size')::bigint = p_taille) then
    raise exception 'PDF absent du stockage ou taille différente : non déclaré disponible';
  end if;
  update public.devis
     set pdf_statut = 'disponible', pdf_chemin = p_chemin, pdf_empreinte = p_empreinte,
         pdf_taille = p_taille, pdf_archive_le = now(), pdf_erreur = null
   where id = p_devis_id;
end
$$;

create or replace function public.signaler_echec_pdf_devis(p_devis_id uuid, p_erreur text)
returns void
language plpgsql
set search_path = public
as $$
begin
  update public.devis set pdf_statut = 'echec', pdf_erreur = left(coalesce(p_erreur, 'Erreur inconnue'), 500)
   where id = p_devis_id and statut <> 'brouillon' and pdf_statut in ('a_generer', 'echec');
end
$$;

create or replace function public.declarer_envoi_devis(p_devis_id uuid, p_auteur uuid, p_date_envoi timestamptz,
                                                       p_canal text, p_destinataire text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_commercial(p_auteur);
  v_devis public.devis;
begin
  select * into v_devis from public.devis where id = p_devis_id for update;
  if not found then
    raise exception 'Devis introuvable';
  end if;
  if v_devis.statut <> 'emis' then
    if v_devis.statut <> 'brouillon' and v_devis.date_envoi = p_date_envoi and v_devis.canal_envoi = p_canal then
      return;  -- déclaration déjà enregistrée
    end if;
    raise exception 'Seul un devis émis peut être déclaré envoyé (statut : %)', v_devis.statut;
  end if;
  update public.devis
     set statut = 'envoye', date_envoi = p_date_envoi, canal_envoi = p_canal,
         envoi_destinataire = nullif(trim(p_destinataire), ''), envoi_declare_par = p_auteur,
         envoi_declare_par_nom = v_nom
   where id = p_devis_id;
end
$$;

create or replace function public.decider_devis(p_devis_id uuid, p_auteur uuid, p_decision text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_commercial(p_auteur);
  v_devis public.devis;
begin
  if p_decision not in ('accepte', 'refuse') then
    raise exception 'Décision inconnue';
  end if;
  select * into v_devis from public.devis where id = p_devis_id for update;
  if not found then
    raise exception 'Devis introuvable';
  end if;
  if v_devis.statut = p_decision then
    return;  -- déjà enregistré
  end if;
  if v_devis.statut <> 'envoye' then
    raise exception 'Seul un devis envoyé peut être accepté ou refusé (statut : %)', v_devis.statut;
  end if;
  update public.devis set statut = p_decision, decision_par = p_auteur, decision_par_nom = v_nom
   where id = p_devis_id;
end
$$;

create or replace function public.creer_nouvelle_version_devis(p_devis_id uuid, p_auteur uuid)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_commercial(p_auteur);
  v_source public.devis;
  v_id uuid;
begin
  select * into v_source from public.devis where id = p_devis_id for update;
  if not found then
    raise exception 'Devis introuvable';
  end if;
  select id into v_id from public.devis where remplace_devis_id = p_devis_id;
  if v_id is not null then
    return v_id;  -- une nouvelle version existe déjà
  end if;
  insert into public.devis (prospect_id, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva,
                            criteres_tva, type_mission, remplace_devis_id)
  values (v_source.prospect_id, v_source.regime_tva, v_source.territoire_tva, v_source.pays_tva,
          v_source.taux_tva, v_source.mention_tva, v_source.criteres_tva, v_source.type_mission, v_source.id)
  returning id into v_id;
  insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire, created_at)
  select v_id, designation, quantite, prix_unitaire, created_at
    from public.devis_lignes where devis_id = v_source.id order by created_at, id;
  return v_id;
end
$$;

create or replace function public.creer_avenant_devis(p_devis_id uuid, p_auteur uuid)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_commercial(p_auteur);
  v_source public.devis;
  v_id uuid;
begin
  select * into v_source from public.devis where id = p_devis_id for update;
  if not found then
    raise exception 'Devis introuvable';
  end if;
  if not exists (select 1 from public.projets where devis_id = v_source.id) then
    raise exception 'Le devis accepté n''a pas de projet : avenant impossible';
  end if;
  insert into public.devis (prospect_id, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva,
                            criteres_tva, type_mission, avenant_du_devis_id)
  values (v_source.prospect_id, v_source.regime_tva, v_source.territoire_tva, v_source.pays_tva,
          v_source.taux_tva, v_source.mention_tva, v_source.criteres_tva, v_source.type_mission, v_source.id)
  returning id into v_id;
  return v_id;
end
$$;

-- Essais autorisés : seul moyen de créer un prospect d'essai (et donc des devis d'essai, numérotés
-- ESSAI-DEV, marqués « ESSAI — SANS VALEUR », clients et projets préfixés [ESSAI]).
create or replace function public.creer_prospect_essai(p_nom text, p_societe text, p_adresse text,
                                                       p_code_postal text, p_ville text, p_pays text)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé aux essais autorisés (clé secrète)';
  end if;
  insert into public.prospects (nom, societe, adresse, code_postal, ville, pays, essai)
  values ('[ESSAI] ' || p_nom, '[ESSAI] ' || p_societe, p_adresse, p_code_postal, p_ville, p_pays, true)
  returning id into v_id;
  return v_id;
end
$$;

-- Nettoyage des essais autorisés (clé secrète) : prospects, devis (tous statuts), lignes, projets et
-- clients d'ESSAI, compteur essai_devis. Refuse tout si une donnée réelle y est rattachée.
-- Renvoie les chemins des PDF d'essai archivés, à supprimer du bucket « devis » par l'appelant.
create or replace function public.supprimer_essais_commercial()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_prospects uuid[];
  v_devis uuid[];
  v_chemins text[];
  v_projets uuid[];
  v_clients uuid[];
  v_nb_lignes integer;
  v_nb_compteurs integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé aux essais autorisés (clé secrète)';
  end if;
  select coalesce(array_agg(id), '{}') into v_prospects from public.prospects where essai;
  select coalesce(array_agg(id), '{}'), coalesce(array_agg(pdf_chemin) filter (where pdf_chemin is not null), '{}')
    into v_devis, v_chemins from public.devis where essai;
  select coalesce(array_agg(id), '{}') into v_projets from public.projets where devis_id = any(v_devis);
  select coalesce(array_agg(distinct client_id), '{}') into v_clients
    from public.prospects where id = any(v_prospects) and client_id is not null;
  if exists (select 1 from public.devis where not essai
              and (remplace_devis_id = any(v_devis) or avenant_du_devis_id = any(v_devis)))
     or exists (select 1 from public.projets where id = any(v_projets) and nom not like '[ESSAI]%')
     or exists (select 1 from public.temps where projet_id = any(v_projets))
     or exists (select 1 from public.clients where id = any(v_clients) and nom not like '[ESSAI]%')
     or exists (select 1 from public.factures where client_id = any(v_clients))
     or exists (select 1 from public.projets where client_id = any(v_clients) and not (id = any(v_projets)))
     or exists (select 1 from public.prospects where client_id = any(v_clients) and not essai) then
    raise exception 'Nettoyage refusé : une donnée réelle est rattachée à un essai ; rien n''a été supprimé';
  end if;
  select count(*) into v_nb_lignes from public.devis_lignes where devis_id = any(v_devis);
  delete from public.projets where id = any(v_projets);
  delete from public.devis where id = any(v_devis);
  delete from public.prospects where id = any(v_prospects);
  delete from public.clients where id = any(v_clients);
  delete from public.compteurs where cle ~ '^essai_devis_[0-9]{4}$';
  get diagnostics v_nb_compteurs = row_count;
  return jsonb_build_object('prospects', cardinality(v_prospects), 'devis', cardinality(v_devis),
    'lignes', v_nb_lignes, 'projets', cardinality(v_projets), 'clients', cardinality(v_clients),
    'compteurs', v_nb_compteurs, 'pdf_chemins', to_jsonb(v_chemins));
end
$$;

-- Aucune de ces fonctions n'est appelable avec un jeton utilisateur.
do $$
declare
  v_fonction text;
begin
  foreach v_fonction in array array[
    'controle_traitement_tva(text, text, text, numeric, text, jsonb)', 'montant_tva(text, numeric, numeric)',
    'verifier_auteur_commercial(uuid)', 'construire_instantane_devis(public.devis)',
    'emettre_devis(uuid, uuid, jsonb, text)', 'enregistrer_pdf_devis(uuid, text, text, bigint)',
    'signaler_echec_pdf_devis(uuid, text)', 'declarer_envoi_devis(uuid, uuid, timestamptz, text, text)',
    'decider_devis(uuid, uuid, text)', 'creer_nouvelle_version_devis(uuid, uuid)',
    'creer_avenant_devis(uuid, uuid)', 'appel_utilisateur()', 'controle_emetteur(jsonb, text)', 'attribuer_numero(text, text)',
    'controle_destinataire(uuid)', 'controle_cumul_avenants(uuid, uuid, numeric)',
    'creer_prospect_essai(text, text, text, text, text, text)', 'supprimer_essais_commercial()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    execute format('grant execute on function public.%s to service_role', v_fonction);
  end loop;
end
$$;

-- 7. Droits -------------------------------------------------------------------------------------
-- 7a. Règles RLS (balayage puis recréation) : admin et manager actifs sur les tables ; le
--     collaborateur passe uniquement par les vues de consultation (section 7c).
do $$
declare
  v_regle record;
begin
  for v_regle in
    select policyname, tablename from pg_policies
     where schemaname = 'public' and tablename in ('prospects', 'devis', 'devis_lignes', 'clients')
  loop
    execute format('drop policy if exists %I on public.%I', v_regle.policyname, v_regle.tablename);
  end loop;
end
$$;

create policy "prospects_commercial" on public.prospects for all to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'))
  with check ((select public.mon_role()) in ('admin', 'manager'));
create policy "devis_commercial" on public.devis for all to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'))
  with check ((select public.mon_role()) in ('admin', 'manager'));
create policy "devis_lignes_commercial" on public.devis_lignes for all to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'))
  with check ((select public.mon_role()) in ('admin', 'manager'));
create policy "clients_lecture_commercial" on public.clients for select to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'));
create policy "clients_ecriture_admin" on public.clients for insert to authenticated
  with check ((select public.est_admin()));
create policy "clients_modification_admin" on public.clients for update to authenticated
  using ((select public.est_admin())) with check ((select public.est_admin()));
create policy "clients_suppression_admin" on public.clients for delete to authenticated
  using ((select public.est_admin()));

-- 7b. Droits de colonnes : les champs gérés par la base ne sont jamais écrits par un jeton.
revoke insert, update on public.devis from authenticated;
grant insert (prospect_id, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, criteres_tva, type_mission)
  on public.devis to authenticated;
grant update (prospect_id, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, criteres_tva, type_mission)
  on public.devis to authenticated;
revoke insert, update on public.devis_lignes from authenticated;
grant insert (devis_id, designation, quantite, prix_unitaire) on public.devis_lignes to authenticated;
grant update (designation, quantite, prix_unitaire) on public.devis_lignes to authenticated;
revoke insert, update on public.prospects from authenticated;
grant insert (nom, societe, email, telephone, source, statut, client_id, adresse, code_postal, ville, pays)
  on public.prospects to authenticated;
grant update (nom, societe, email, telephone, source, statut, client_id, adresse, code_postal, ville, pays)
  on public.prospects to authenticated;

-- 7c. Consultation par le collaborateur : vues à colonnes explicites, lecture seule.
--     Ni coordonnées des prospects, ni table clients, ni critères fiscaux (n° TVA du client),
--     ni destinataire d'envoi, ni instantané, ni PDF.
drop view if exists public.commercial_prospects;
drop view if exists public.commercial_devis;
drop view if exists public.commercial_devis_lignes;

create view public.commercial_prospects with (security_barrier = true) as
  select p.id, p.nom, p.societe, p.source, p.statut, p.essai, p.created_at
    from public.prospects p
   where (select public.mon_role()) in ('admin', 'manager', 'collaborateur');

create view public.commercial_devis with (security_barrier = true) as
  select d.id, d.prospect_id, d.numero, d.date_emission, d.statut, d.total_ht, d.tva, d.total_ttc,
         d.regime_tva, d.territoire_tva, d.pays_tva, d.taux_tva, d.mention_tva, d.date_envoi, d.canal_envoi,
         d.remplace_devis_id, d.avenant_du_devis_id, d.essai, d.type_mission, d.created_at
    from public.devis d
   where (select public.mon_role()) in ('admin', 'manager', 'collaborateur');

create view public.commercial_devis_lignes with (security_barrier = true) as
  select l.id, l.devis_id, l.designation, l.quantite, l.prix_unitaire, l.montant_ht, l.created_at
    from public.devis_lignes l
   where (select public.mon_role()) in ('admin', 'manager', 'collaborateur');

revoke all on public.commercial_prospects, public.commercial_devis, public.commercial_devis_lignes
  from public, anon, authenticated;
grant select on public.commercial_prospects, public.commercial_devis, public.commercial_devis_lignes
  to authenticated, service_role;

-- 7d. F. Bucket privé d'archivage des devis : aucune règle → seule la clé secrète y accède.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('devis', 'devis', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
                               allowed_mime_types = array['application/pdf'];

-- 8. Contrôles ------------------------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_admin uuid;
  v_prospect uuid;
  v_devis uuid;
  v_version uuid;
  v_numero text;
  v_numero2 text;
  v_ok boolean;
  v_compteurs_avant text;
  v_compteurs_apres text;
  v_sequences_avant text;
  v_sequences_apres text;
  v_lignes_avant text;
  v_lignes_apres text;
  v_emetteur constant jsonb := '{"raison_sociale":"AUTOTEST","forme_juridique":"SAS","capital_social":"1",
    "adresse":"1 rue de l''Essai","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000",
    "immatriculation":"RCS essai","tva_intracom":"FR00000000000","validite_jours":"30",
    "obligation_assurance":"non_requise"}';
begin
  -- Inventaire des fonctions exécutables avec un jeton : toujours les 4 fonctions d'identité.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Commercial : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Commercial : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'Commercial : fonction(s) manipulant taux_horaire : %', v_liste;
  end if;

  -- Toutes les règles passent par le contrôle de session active.
  select string_agg(tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, ''))
         !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'Commercial : règles sans contrôle de session active : %', v_liste;
  end if;

  -- Vues : lecture seule, aucun visiteur, colonnes sensibles absentes.
  if has_table_privilege('authenticated', 'public.commercial_devis', 'insert, update, delete')
     or has_table_privilege('authenticated', 'public.commercial_prospects', 'insert, update, delete')
     or has_table_privilege('authenticated', 'public.commercial_devis_lignes', 'insert, update, delete')
     or has_table_privilege('anon', 'public.commercial_devis', 'select')
     or has_table_privilege('anon', 'public.commercial_prospects', 'select')
     or has_table_privilege('anon', 'public.commercial_devis_lignes', 'select') then
    raise exception 'Commercial : vues de consultation trop ouvertes';
  end if;
  select string_agg(table_name || '.' || column_name, ', ') into v_liste
    from information_schema.columns
   where table_schema = 'public' and table_name like 'commercial\_%'
     and column_name in ('email', 'telephone', 'client_id', 'criteres_tva', 'envoi_destinataire',
                         'instantane_emission', 'pdf_chemin', 'pdf_empreinte', 'taux_horaire', 'adresse',
                         'code_postal', 'ville', 'emis_par', 'envoi_declare_par', 'decision_par');
  if v_liste is not null then
    raise exception 'Commercial : colonnes sensibles exposées au collaborateur : %', v_liste;
  end if;

  -- Colonnes gérées par la base : jamais écrites avec un jeton.
  if has_column_privilege('authenticated', 'public.devis', 'statut', 'update')
     or has_column_privilege('authenticated', 'public.devis', 'numero', 'update')
     or has_column_privilege('authenticated', 'public.devis', 'total_ttc', 'update')
     or has_column_privilege('authenticated', 'public.devis', 'pdf_statut', 'update')
     or has_column_privilege('authenticated', 'public.devis', 'statut', 'insert')
     or has_column_privilege('authenticated', 'public.devis_lignes', 'montant_ht', 'update') then
    raise exception 'Commercial : une colonne gérée par la base reste modifiable avec un jeton';
  end if;

  -- Bucket privé.
  select count(*) into v_nb from storage.buckets where id = 'devis' and not public;
  if v_nb <> 1 then
    raise exception 'Commercial : bucket privé « devis » absent';
  end if;

  -- Essai complet, annulé à la fin. Empreinte AVANT : compteurs (clé=valeur), valeur courante de
  -- toutes les séquences du schéma public, nombre de lignes des tables touchées.
  select coalesce(string_agg(cle || '=' || valeur, ',' order by cle), '') into v_compteurs_avant from public.compteurs;
  select coalesce(string_agg(schemaname || '.' || sequencename || '=' || coalesce(last_value, 0), ',' order by sequencename), '')
    into v_sequences_avant from pg_sequences where schemaname not in ('pg_catalog', 'information_schema');
  select (select count(*) from public.clients) || '/' || (select count(*) from public.projets) || '/'
         || (select count(*) from public.prospects) || '/' || (select count(*) from public.devis) || '/'
         || (select count(*) from public.devis_lignes) || '/' || (select count(*) from storage.objects)
    into v_lignes_avant;
  select id into v_admin from public.profiles where role = 'admin' limit 1;
  -- Précision des colonnes de montants relevée dans Supabase le 23/10/2026 (diagnostic_totaux_devis.sql) :
  -- les calculs et l'autotest la supposent ; si elle change, le déploiement s'arrête pour réexamen.
  select string_agg(table_name || '.' || column_name || '='
                    || coalesce(numeric_precision || ',' || numeric_scale, 'sans précision fixée'), ' '
                    order by table_name, column_name)
    into v_liste
    from information_schema.columns
   where table_schema = 'public'
     and (table_name, column_name) in (('devis', 'total_ht'), ('devis', 'tva'), ('devis', 'total_ttc'),
                                       ('devis_lignes', 'quantite'), ('devis_lignes', 'prix_unitaire'),
                                       ('devis_lignes', 'montant_ht'));
  if v_liste is distinct from 'devis.total_ht=12,2 devis.total_ttc=12,2 devis.tva=12,2 devis_lignes.montant_ht=12,2 '
                              'devis_lignes.prix_unitaire=12,2 devis_lignes.quantite=10,2' then
    raise exception 'Commercial : précision des montants différente de celle examinée (%) ; nouvel examen nécessaire',
      coalesce(v_liste, 'colonnes absentes');
  end if;

  begin
    v_prospect := public.creer_prospect_essai('Autotest', 'Autotest SARL', '1 rue de l''Essai', '97200',
                                              'Fort-de-France', 'MQ');
    insert into public.devis (prospect_id) values (v_prospect) returning id into v_devis;
    insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
      values (v_devis, 'Étude', 0.33, 100.01), (v_devis, 'Visites', 3, 100.33), (v_devis, 'Gratuit', 1, 0);
    -- Les valeurs d'essai tiennent dans les colonnes (2 décimales) : aucune n'a été arrondie à l'enregistrement.
    select count(*) = 3 and bool_and((quantite, prix_unitaire) in ((0.33, 100.01), (3, 100.33), (1, 0)))
      into v_ok from public.devis_lignes where devis_id = v_devis;
    if not v_ok then
      raise exception 'AUTOTEST: valeurs d''essai modifiées à l''enregistrement des lignes';
    end if;
    -- Arrondi de ligne : 0,33 × 100,01 = 33,0033 → 33,00 ; 3 × 100,33 = 300,99.
    select string_agg(montant_ht::text, ' ' order by montant_ht) into v_liste from public.devis_lignes where devis_id = v_devis;
    if v_liste is distinct from '0.00 33.00 300.99' then
      raise exception 'AUTOTEST: montants de ligne incorrects (%)', v_liste;
    end if;
    update public.devis set regime_tva = 'taxable', territoire_tva = 'MQ', taux_tva = 8.5, type_mission = 'conseil',
           criteres_tva = '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
     where id = v_devis;
    -- Totaux : HT 333,99 ; TVA 8,5 % = 28,38915 → 28,39 ; TTC 362,38.
    select total_ht = 333.99 and tva = 28.39 and total_ttc = 362.38, total_ht || ' / ' || tva || ' / ' || total_ttc
      into v_ok, v_liste from public.devis where id = v_devis;
    if not v_ok then
      raise exception 'AUTOTEST: totaux du brouillon incorrects (HT / TVA / TTC obtenus : %)', v_liste;
    end if;

    begin
      perform public.emettre_devis(v_devis, v_admin, '{"raison_sociale":"Autotest"}', 'v1');
      raise exception 'AUTOTEST: émission acceptée avec des coordonnées incomplètes';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise; end if;
    end;
    v_numero := public.emettre_devis(v_devis, v_admin, v_emetteur, 'v1');
    v_numero2 := public.emettre_devis(v_devis, v_admin, v_emetteur, 'v1');
    if v_numero is null or v_numero not like 'ESSAI-DEV-%' or v_numero2 <> v_numero then
      raise exception 'AUTOTEST: numérotation incorrecte (% / %)', v_numero, v_numero2;
    end if;
    begin
      update public.devis_lignes set prix_unitaire = 1 where devis_id = v_devis;
      raise exception 'AUTOTEST: ligne modifiée après émission';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise; end if;
    end;
    begin
      perform public.declarer_envoi_devis(v_devis, v_admin, now(), 'email', 'x@exemple.invalid');
      raise exception 'AUTOTEST: envoi déclaré sans PDF disponible';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise; end if;
    end;
    update public.devis set pdf_statut = 'disponible', pdf_chemin = v_devis || '/' || v_numero || '.pdf',
           pdf_empreinte = repeat('a', 64), pdf_taille = 100, pdf_archive_le = now()
     where id = v_devis;
    perform public.declarer_envoi_devis(v_devis, v_admin, now(), 'email', 'x@exemple.invalid');
    if (select statut from public.prospects where id = v_prospect) <> 'devis_envoye' then
      raise exception 'AUTOTEST: prospect non passé à « devis envoyé »';
    end if;
    v_version := public.creer_nouvelle_version_devis(v_devis, v_admin);
    if (select count(*) from public.devis_lignes where devis_id = v_version) <> 3 then
      raise exception 'AUTOTEST: nouvelle version sans ses lignes';
    end if;
    delete from public.devis where id = v_version;

    -- Acceptation par simple changement de statut (comme depuis le tableau de bord).
    update public.devis set statut = 'accepte' where id = v_devis;
    select count(*) into v_nb from public.projets where devis_id = v_devis;
    if v_nb <> 1 or (select statut from public.prospects where id = v_prospect) <> 'gagne'
       or (select client_id from public.prospects where id = v_prospect) is null then
      raise exception 'AUTOTEST: acceptation sans client, projet ou prospect gagné';
    end if;
    begin
      perform public.creer_nouvelle_version_devis(v_devis, v_admin);
      raise exception 'AUTOTEST: devis accepté remplacé';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise; end if;
    end;
    begin
      update public.prospects set statut = 'perdu' where id = v_prospect;
      raise exception 'AUTOTEST: prospect gagné repassé à perdu';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise; end if;
    end;
    -- Nettoyage des essais : tout disparaît (devis accepté compris), rien de réel n'est touché.
    perform public.supprimer_essais_commercial();
    if exists (select 1 from public.prospects where essai) or exists (select 1 from public.devis where essai)
       or exists (select 1 from public.projets where devis_id = v_devis)
       or exists (select 1 from public.compteurs where cle ~ '^essai_devis_') then
      raise exception 'AUTOTEST: nettoyage des essais incomplet';
    end if;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'Commercial : autotest en échec : %', sqlerrm;
    end if;
  end;

  -- Empreinte APRÈS : identique, sinon le déploiement échoue (et rien n'est appliqué).
  select coalesce(string_agg(cle || '=' || valeur, ',' order by cle), '') into v_compteurs_apres from public.compteurs;
  select coalesce(string_agg(schemaname || '.' || sequencename || '=' || coalesce(last_value, 0), ',' order by sequencename), '')
    into v_sequences_apres from pg_sequences where schemaname not in ('pg_catalog', 'information_schema');
  select (select count(*) from public.clients) || '/' || (select count(*) from public.projets) || '/'
         || (select count(*) from public.prospects) || '/' || (select count(*) from public.devis) || '/'
         || (select count(*) from public.devis_lignes) || '/' || (select count(*) from storage.objects)
    into v_lignes_apres;
  if v_compteurs_apres is distinct from v_compteurs_avant then
    raise exception 'Commercial : l''autotest a modifié les compteurs (% → %)', v_compteurs_avant, v_compteurs_apres;
  end if;
  if v_sequences_apres is distinct from v_sequences_avant then
    raise exception 'Commercial : l''autotest a fait avancer une séquence (% → %)', v_sequences_avant, v_sequences_apres;
  end if;
  if v_lignes_apres is distinct from v_lignes_avant then
    raise exception 'Commercial : l''autotest a laissé des lignes (% → %)', v_lignes_avant, v_lignes_apres;
  end if;
end
$$;
