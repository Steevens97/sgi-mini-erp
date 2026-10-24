-- Module Finance (1re version) : facturation des temps passés, émission numérotée, PDF archivé, envoi déclaré,
-- règlement intégral déclaré. Décisions de l'utilisateur du 24/10/2026 (voir CLAUDE.md, section Finance) :
--   - seuls les projets explicitement « au temps passé » sont facturables ; forfaits, avoirs, relances, paiements
--     partiels, emails et suivi bancaire : hors de cette version ;
--   - tarif horaire de VENTE confirmé par projet, à date d'effet, distinct du coût interne (taux_horaire, jamais lu) ;
--   - seuls les temps VALIDÉS et non facturés sont facturés (les temps « soumis » ou attestés de l'administrateur
--     ne le sont jamais) ; un temps n'est facturé qu'une fois, puis figé avec son tarif et son montant ;
--   - aperçu sans numéro ni réservation ; émission en une transaction (verrous, recalcul, empreinte de l'aperçu,
--     numéro FAC-AAAA-NNNN au fuseau de la Martinique, instantané figé), retrouvée à l'identique si elle est rejouée ;
--   - une facture émise ne se modifie ni ne se supprime ; essais seuls supprimables (clé secrète) ;
--   - Finance réservé à l'administrateur ; tarifs et montants figés illisibles avec tout jeton utilisateur.
-- Compatible avec le site en ligne : aucune colonne existante n'est modifiée ; les lectures existantes de projets
-- et temps nomment leurs colonnes (vérifié), qui restent lisibles.

-- 0. Préalables -----------------------------------------------------------------------------------------------
do $$
declare
  v_src text;
  v_nb integer;
begin
  select count(*) into v_nb from supabase_migrations.schema_migrations where version in ('20261025100000', '20261026100000');
  if v_nb <> 2 then
    raise exception 'Finance : les migrations RH 20261025100000 et 20261026100000 doivent être appliquées avant';
  end if;
  -- Même examen que le module Commercial : la numérotation reste transactionnelle.
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'prochain_numero'
     and pg_get_function_identity_arguments(p.oid) = 'p_cle text, p_prefixe text';
  if v_src is null or md5(btrim(regexp_replace(v_src, '\s+', ' ', 'g'))) <> '72f806be71e542bd2983dd16ce16b808' then
    raise exception 'Finance : prochain_numero absente ou différente de la définition examinée le 23/10/2026 ; nouvel examen nécessaire';
  end if;
  -- Fonctions existantes que ce module remplace : elles doivent être EXACTEMENT celles des migrations appliquées
  -- (sinon une version inconnue serait écrasée) — même méthode que l'examen de prochain_numero.
  select string_agg(p.proname, ', ' order by p.proname) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname, md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')))) in (
           ('temps_controle', 'b433bf39687070c13ca7c076952bcf91'),
           ('factures_avant_suppression', 'ed102f1600ec349ae8d0cbcee6fbdd5b'),
           ('attribuer_numero', '0788f1e2e5ea9260ee71b80afe965fc1'));
  if v_src is distinct from 'attribuer_numero, factures_avant_suppression, temps_controle' then
    raise exception 'Finance : temps_controle, factures_avant_suppression ou attribuer_numero diffèrent des versions appliquées (trouvées conformes : %) ; nouvel examen nécessaire',
      coalesce(v_src, 'aucune');
  end if;
  select count(*) into v_nb from public.factures;
  if v_nb > 0 then
    raise exception 'Finance : % facture(s) existent déjà ; examen nécessaire avant de poser les règles', v_nb;
  end if;
  select count(*) into v_nb from public.temps where facture_id is not null;
  if v_nb > 0 then
    raise exception 'Finance : % temps sont déjà rattachés à une facture ; examen nécessaire', v_nb;
  end if;
  select count(*) into v_nb from public.compteurs where cle ~ '^(facture|essai_facture)_';
  if v_nb > 0 then
    raise exception 'Finance : un compteur de factures existe déjà ; examen nécessaire';
  end if;
end
$$;

-- 1. Colonnes (approuvées par l'utilisateur le 24/10/2026) ---------------------------------------------------------
alter table public.projets
  add column if not exists mode_facturation text,            -- temps_passe | forfait | non_facturable ; vide = à définir
  add column if not exists tarif_vente_ht numeric(10, 2),    -- DERNIER tarif confirmé (récapitulatif)
  add column if not exists tarif_reference text,
  add column if not exists tarif_date_effet date,
  add column if not exists tarif_confirme_par uuid,
  add column if not exists tarif_confirme_par_nom text,
  add column if not exists tarif_confirme_le timestamptz,
  add column if not exists tarif_historique jsonb not null default '[]'::jsonb;  -- périodes et corrections, ajout seul

alter table public.factures
  add column if not exists essai boolean not null default false,
  add column if not exists instantane_emission jsonb,
  add column if not exists emise_par uuid,
  add column if not exists emise_par_nom text,
  add column if not exists emise_le timestamptz,
  add column if not exists pdf_statut text,
  add column if not exists pdf_chemin text,
  add column if not exists pdf_empreinte text,
  add column if not exists pdf_taille bigint,
  add column if not exists pdf_archive_le timestamptz,
  add column if not exists pdf_erreur text,
  add column if not exists cle_emission uuid,
  add column if not exists empreinte_apercu text,
  add column if not exists historique jsonb not null default '[]'::jsonb,
  add column if not exists date_reglement date,
  add column if not exists mode_reglement text,
  add column if not exists reference_reglement text,
  add column if not exists reglement_declare_par uuid,
  add column if not exists reglement_declare_par_nom text,
  add column if not exists reglement_declare_le timestamptz;

alter table public.temps
  add column if not exists taux_facture numeric(10, 2),         -- tarif de vente réellement facturé, figé
  add column if not exists montant_facture_ht numeric(12, 2);   -- heures × taux, arrondi au centime, figé

-- 2. Contraintes ---------------------------------------------------------------------------------------------------
do $$
declare
  v_c record;
begin
  for v_c in select conname, conrelid::regclass::text as t from pg_constraint
              where conrelid in ('public.projets'::regclass, 'public.factures'::regclass, 'public.temps'::regclass)
                and conname in ('projets_mode_facturation_liste', 'projets_tarif_positif', 'factures_pdf_statut_liste',
                                'factures_mode_reglement_liste', 'factures_totaux_coherents', 'temps_facturation_complete')
  loop
    execute format('alter table %s drop constraint %I', v_c.t, v_c.conname);
  end loop;
end
$$;
alter table public.projets add constraint projets_mode_facturation_liste
  check (mode_facturation is null or mode_facturation in ('temps_passe', 'forfait', 'non_facturable'));
alter table public.projets add constraint projets_tarif_positif check (tarif_vente_ht is null or tarif_vente_ht > 0);
alter table public.factures add constraint factures_pdf_statut_liste
  check (pdf_statut is null or pdf_statut in ('a_generer', 'disponible', 'echec'));
alter table public.factures add constraint factures_mode_reglement_liste
  check (mode_reglement is null or mode_reglement in ('virement', 'cheque', 'especes', 'carte', 'autre'));
alter table public.factures add constraint factures_totaux_coherents check (total_ttc = total_ht + tva) not valid;
alter table public.temps add constraint temps_facturation_complete
  check ((facture_id is null and taux_facture is null and montant_facture_ht is null)
         or (facture_id is not null and taux_facture > 0 and montant_facture_ht = round(heures * taux_facture, 2)))
  not valid;
create unique index if not exists factures_cle_emission_unique on public.factures (cle_emission) where cle_emission is not null;

-- 3. Outils internes -----------------------------------------------------------------------------------------------
-- Numérotation : les clés de facture rejoignent les clés prévues (même règle, même limite de 9 999 par an).
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
  if p_cle not in ('devis', 'essai_devis', 'facture', 'essai_facture') then
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

-- Auteur d'une action Finance : administrateur actif (mot de passe définitif, non banni).
create or replace function public.verifier_auteur_finance(p_auteur uuid)
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
   where p.id = p_auteur and p.role = 'admin'
     and (u.banned_until is null or u.banned_until <= now())
     and coalesce((u.raw_app_meta_data ->> 'doit_changer_mot_de_passe')::boolean, false) = false;
  if v_nom is null then
    raise exception 'Finance : action réservée à un administrateur actif.';
  end if;
  return v_nom;
end
$$;

-- Contexte posé par les fonctions Finance pour leurs déclencheurs (local à la transaction, inaccessible aux jetons).
create or replace function public.finance_contexte(p_operation text, p_evenement jsonb, p_facture uuid)
returns void
language sql
as $$
  select set_config('sgi.fin_operation', coalesce(p_operation, ''), true),
         set_config('sgi.fin_evenement', coalesce(p_evenement::text, ''), true),
         set_config('sgi.fin_facture', coalesce(p_facture::text, ''), true);
$$;

create or replace function public.finance_fin_contexte()
returns void
language sql
as $$
  select set_config('sgi.fin_operation', '', true), set_config('sgi.fin_evenement', '', true),
         set_config('sgi.fin_facture', '', true);
$$;

-- Périodes tarifaires en vigueur : toutes les périodes confirmées, sauf celles qu'une correction remplace.
-- L'historique n'est jamais modifié : une correction AJOUTE un événement qui désigne la période remplacée.
create or replace function public.finance_periodes_actives(p_historique jsonb)
returns table (id text, tarif numeric, date_effet date, reference text)
language sql
immutable
as $$
  select e ->> 'id', (e ->> 'tarif')::numeric, (e ->> 'date_effet')::date, e ->> 'reference'
    from jsonb_array_elements(coalesce(p_historique, '[]'::jsonb)) e
   where e ->> 'type' in ('periode', 'correction')
     and not exists (select 1 from jsonb_array_elements(coalesce(p_historique, '[]'::jsonb)) r
                      where r ->> 'remplace' = e ->> 'id');
$$;

-- Tarif contractuel applicable à une date travaillée : la période en vigueur la plus récente qui a commencé.
create or replace function public.finance_tarif_a_date(p_historique jsonb, p_date date)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('id', a.id, 'tarif', a.tarif, 'date_effet', a.date_effet, 'reference', a.reference)
    from public.finance_periodes_actives(p_historique) a
   where a.date_effet <= p_date
   order by a.date_effet desc
   limit 1;
$$;

-- Temps non facturés d'un projet travaillés à partir d'une date : ceux qu'un tarif à cette date d'effet toucherait.
-- L'empreinte couvre l'identité, la date et les heures de chaque temps : toute modification la change.
create or replace function public.finance_temps_concernes(p_projet uuid, p_date_effet date)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'nb', count(t.id),
    'heures', coalesce(sum(t.heures), 0),
    'empreinte', md5(coalesce(string_agg(t.id || '|' || t.date_saisie || '|' || t.heures, ';' order by t.id), '')),
    'deja_factures', (select count(*) from public.temps f
                       where f.projet_id = p_projet and f.date_saisie >= p_date_effet and f.facture_id is not null),
    'liste', coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'date', t.date_saisie, 'heures', t.heures,
                                                   'statut', t.statut, 'collaborateur', concat_ws(' ', c.prenom, c.nom))
                                order by t.date_saisie, t.id), '[]'::jsonb))
    from public.temps t join public.collaborateurs c on c.id = t.collaborateur_id
   where t.projet_id = p_projet and t.date_saisie >= p_date_effet and t.facture_id is null;
$$;

-- Coordonnées de l'émetteur et conditions de paiement d'une facture (vides tant que l'utilisateur ne les a pas
-- fournies : l'émission réelle reste bloquée). Valeurs de démonstration interdites sur une facture réelle.
create or replace function public.finance_controle_emetteur(p_emetteur jsonb, p_conditions jsonb, p_essai boolean)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_manquants text[] := '{}';
  v_cle text;
begin
  if p_emetteur is null or jsonb_typeof(p_emetteur) <> 'object' or p_conditions is null
     or jsonb_typeof(p_conditions) <> 'object' then
    return 'coordonnées de l''émetteur ou conditions de paiement absentes';
  end if;
  foreach v_cle in array array['raison_sociale', 'forme_juridique', 'adresse', 'code_postal', 'ville', 'siret',
                               'immatriculation', 'tva_intracom'] loop
    if coalesce(trim(p_emetteur ->> v_cle), '') = '' then
      v_manquants := array_append(v_manquants, v_cle);
    end if;
  end loop;
  if upper(coalesce(p_emetteur ->> 'forme_juridique', '')) in ('SARL', 'EURL', 'SAS', 'SASU', 'SA', 'SNC',
                                                               'SELARL', 'SELAS')
     and coalesce(trim(p_emetteur ->> 'capital_social'), '') = '' then
    v_manquants := array_append(v_manquants, 'capital_social');
  end if;
  foreach v_cle in array array['delai_paiement_jours', 'penalites_retard', 'indemnite_recouvrement', 'escompte'] loop
    if coalesce(trim(p_conditions ->> v_cle), '') = '' then
      v_manquants := array_append(v_manquants, v_cle);
    end if;
  end loop;
  if cardinality(v_manquants) > 0 then
    return 'coordonnées ou conditions de paiement de SG Ingénierie incomplètes : ' || array_to_string(v_manquants, ', ');
  end if;
  if replace(p_emetteur ->> 'siret', ' ', '') !~ '^[0-9]{14}$' then
    return 'SIRET de l''émetteur invalide (14 chiffres)';
  end if;
  if (p_conditions ->> 'delai_paiement_jours') !~ '^[1-9][0-9]{0,2}$' then
    return 'délai de paiement invalide (nombre de jours)';
  end if;
  if not p_essai and (p_emetteur::text ilike '%[DÉMO]%' or p_conditions::text ilike '%[DÉMO]%') then
    return 'coordonnées ou conditions de démonstration interdites sur une facture réelle';
  end if;
  return null;
end
$$;

-- 4. Calcul (aperçu ET émission : une seule fonction, donc les mêmes montants) -----------------------------------------
-- Règle d'arrondi unique : montant de chaque temps = heures × tarif arrondi au centime ; ligne (projet × période
-- tarifaire) = somme des montants arrondis ; total HT = somme des lignes ; TVA = total HT × taux arrondi au centime ;
-- TTC = HT + TVA. L'écart entre une ligne et « total des heures × tarif » est calculé et montré, jamais corrigé.
create or replace function public.finance_calculer(p_client uuid, p_mois date, p_projets uuid[], p_tva jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_debut date := date_trunc('month', coalesce(p_mois, current_date))::date;
  v_fin date := (date_trunc('month', coalesce(p_mois, current_date)) + interval '1 month - 1 day')::date;
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  v_client public.clients;
  v_blocages text[] := '{}';
  v_projets jsonb := '[]'::jsonb;
  v_temps jsonb := '[]'::jsonb;
  v_lignes jsonb;
  v_essais boolean[] := '{}';
  v_essai boolean := false;
  v_regime text := nullif(btrim(coalesce(p_tva ->> 'regime', '')), '');
  v_territoire text := nullif(btrim(coalesce(p_tva ->> 'territoire', '')), '');
  v_pays text := nullif(btrim(coalesce(p_tva ->> 'pays', '')), '');
  v_taux numeric := nullif(btrim(coalesce(p_tva ->> 'taux', '')), '')::numeric;
  v_mention text := nullif(btrim(coalesce(p_tva ->> 'mention', '')), '');
  v_criteres jsonb := case when jsonb_typeof(p_tva -> 'criteres') = 'object' then p_tva -> 'criteres' end;
  v_erreur text;
  v_message text;
  v_nb integer := 0;
  v_periode jsonb;
  v_tarif numeric;
  v_ht numeric;
  v_montant_tva numeric;
  v_heures numeric;
  r record;
begin
  if p_mois is null then
    v_blocages := array_append(v_blocages, 'Mois à facturer manquant.');
  elsif v_debut > v_aujourdhui then
    v_blocages := array_append(v_blocages, 'Mois futur : facturation impossible.');
  end if;
  select * into v_client from public.clients where id = p_client;
  if not found then
    v_blocages := array_append(v_blocages, 'Client introuvable.');
  elsif coalesce(btrim(v_client.adresse), '') = '' then
    v_blocages := array_append(v_blocages, 'Adresse du client manquante : complétez la fiche client avant d''émettre.');
  end if;
  if coalesce(cardinality(p_projets), 0) = 0 then
    v_blocages := array_append(v_blocages, 'Sélectionnez au moins un projet.');
  end if;

  -- TVA : traitement complet et cohérent, identique à celui des devis des projets choisis.
  if v_regime is null then
    v_blocages := array_append(v_blocages, 'Traitement de TVA à renseigner.');
  else
    v_erreur := public.controle_traitement_tva(v_regime, v_territoire, v_pays, v_taux, v_mention, v_criteres);
    if v_erreur is not null then
      v_blocages := array_append(v_blocages, 'TVA : ' || v_erreur);
    end if;
  end if;

  for r in
    select p.id, p.nom, p.client_id, p.mode_facturation, p.tarif_historique, d.id as devis_id, d.numero as devis_numero,
           coalesce(d.essai, false) as essai, d.regime_tva, d.territoire_tva, d.pays_tva, d.taux_tva
      from public.projets p left join public.devis d on d.id = p.devis_id
     where p.id = any(p_projets)
     order by p.nom, p.id
  loop
    v_nb := v_nb + 1;
    v_essais := array_append(v_essais, r.essai);
    v_projets := v_projets || jsonb_build_array(jsonb_build_object('id', r.id, 'nom', r.nom, 'devis_numero', r.devis_numero));
    if r.client_id is distinct from p_client then
      v_blocages := array_append(v_blocages, format('Le projet « %s » n''appartient pas à ce client.', r.nom));
    end if;
    if r.mode_facturation is distinct from 'temps_passe' then
      v_blocages := array_append(v_blocages, format(
        'Projet « %s » : mode de facturation « %s » ; seuls les projets au temps passé sont facturables dans cette version.',
        r.nom, case r.mode_facturation when 'forfait' then 'forfait' when 'non_facturable' then 'non facturable'
                                       else 'à définir' end));
    end if;
    if not exists (select 1 from public.finance_periodes_actives(r.tarif_historique)) then
      v_blocages := array_append(v_blocages, format('Tarif de vente non confirmé pour le projet « %s » : facturation impossible.', r.nom));
    end if;
    if r.devis_id is not null and r.regime_tva is not null and v_regime is not null
       and (r.regime_tva, r.territoire_tva, r.pays_tva, r.taux_tva) is distinct from (v_regime, v_territoire, v_pays, v_taux) then
      v_blocages := array_append(v_blocages, format(
        'TVA incompatible : le projet « %s » relève du devis %s (%s%s, %s%s) ; facturez-le séparément ou avec le même traitement.',
        r.nom, r.devis_numero, r.regime_tva, coalesce(' ' || r.taux_tva || ' %', ''), r.territoire_tva,
        coalesce(' ' || r.pays_tva, '')));
    end if;
  end loop;
  if v_nb < coalesce(cardinality(array(select distinct unnest(p_projets))), 0) then
    v_blocages := array_append(v_blocages, 'Un projet sélectionné est introuvable.');
  end if;

  -- Essais : jamais mélangés avec des données réelles.
  if cardinality(v_essais) > 0 then
    if true = any(v_essais) and false = any(v_essais) then
      v_blocages := array_append(v_blocages, 'Projets d''essai et projets réels mélangés : facturation impossible.');
    end if;
    v_essai := true = all(v_essais);
    if v_client.id is not null and v_essai <> (v_client.nom like '[ESSAI]%') then
      v_blocages := array_append(v_blocages, 'Client et projets incohérents (essai / réel) : facturation impossible.');
    end if;
  end if;

  -- Temps facturables : validés, non facturés, du mois, sur les projets choisis au temps passé de ce client.
  for r in
    select t.id, t.date_saisie, t.heures, t.projet_id, p.nom as projet_nom, p.tarif_historique,
           concat_ws(' ', c.prenom, c.nom) as intervenant
      from public.temps t
      join public.projets p on p.id = t.projet_id
      join public.collaborateurs c on c.id = t.collaborateur_id
     where t.projet_id = any(p_projets) and p.client_id = p_client and p.mode_facturation = 'temps_passe'
       and t.statut = 'valide' and t.facture_id is null and t.date_saisie between v_debut and v_fin
     order by t.date_saisie, t.id
  loop
    v_periode := public.finance_tarif_a_date(r.tarif_historique, r.date_saisie);
    v_tarif := (v_periode ->> 'tarif')::numeric;
    if v_periode is null then
      v_message := format('Aucun tarif contractuel en vigueur le %s pour le projet « %s ».',
                          to_char(r.date_saisie, 'DD/MM/YYYY'), r.projet_nom);
      if not (v_message = any(v_blocages)) then v_blocages := array_append(v_blocages, v_message); end if;
      continue;
    end if;
    if v_tarif is null or v_tarif <= 0 then
      v_message := format('Tarif de vente non confirmé pour le projet « %s » : facturation impossible.', r.projet_nom);
      if not (v_message = any(v_blocages)) then v_blocages := array_append(v_blocages, v_message); end if;
      continue;
    end if;
    v_temps := v_temps || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'date', r.date_saisie, 'intervenant', r.intervenant, 'projet_id', r.projet_id, 'projet_nom', r.projet_nom,
      'heures', r.heures, 'periode_id', v_periode ->> 'id', 'date_effet', v_periode ->> 'date_effet',
      'reference', v_periode ->> 'reference', 'tarif', v_tarif, 'montant_ht', round(r.heures * v_tarif, 2)));
  end loop;
  if jsonb_array_length(v_temps) = 0 then
    v_blocages := array_append(v_blocages, 'Aucun temps validé et non facturé sur les projets choisis pour ce mois.');
  end if;

  -- Lignes : un projet × une période tarifaire ; écart d'arrondi montré.
  select coalesce(jsonb_agg(jsonb_build_object(
           'projet_id', l.projet_id, 'projet_nom', l.projet_nom, 'periode_id', l.periode_id, 'date_effet', l.date_effet,
           'reference', l.reference, 'tarif', l.tarif, 'nb_temps', l.nb, 'heures', l.heures, 'montant_ht', l.montant,
           'montant_theorique', round(l.heures * l.tarif, 2), 'ecart_arrondi', l.montant - round(l.heures * l.tarif, 2))
         order by l.projet_nom, l.date_effet), '[]'::jsonb),
         coalesce(sum(l.montant), 0), coalesce(sum(l.heures), 0)
    into v_lignes, v_ht, v_heures
    from (select e ->> 'projet_id' as projet_id, e ->> 'projet_nom' as projet_nom, e ->> 'periode_id' as periode_id,
                 (e ->> 'date_effet')::date as date_effet, e ->> 'reference' as reference, (e ->> 'tarif')::numeric as tarif,
                 count(*) as nb, sum((e ->> 'heures')::numeric) as heures, sum((e ->> 'montant_ht')::numeric) as montant
            from jsonb_array_elements(v_temps) e
           group by 1, 2, 3, 4, 5, 6) l;
  v_montant_tva := case when v_regime = 'taxable' and v_taux is not null then round(v_ht * v_taux / 100, 2) else 0 end;

  return jsonb_build_object(
    'client', case when v_client.id is null then null else
              jsonb_build_object('id', v_client.id, 'nom', v_client.nom, 'adresse', v_client.adresse,
                                 'email', v_client.email_contact, 'telephone', v_client.telephone) end,
    'mois', to_char(v_debut, 'YYYY-MM'), 'periode_debut', v_debut, 'periode_fin', v_fin,
    'essai', v_essai, 'projets', v_projets, 'lignes', v_lignes, 'temps', v_temps,
    'totaux', jsonb_build_object('heures', v_heures, 'total_ht', v_ht, 'tva', v_montant_tva, 'total_ttc', v_ht + v_montant_tva),
    'tva', jsonb_build_object('regime', v_regime, 'territoire', v_territoire, 'pays', v_pays, 'taux', v_taux,
                              'mention', v_mention, 'criteres', v_criteres),
    'blocages', to_jsonb(v_blocages),
    -- Empreinte de la sélection : client, mois, projets, TVA et chaque temps (identité, date, heures, tarif).
    'empreinte', md5(jsonb_build_object(
      'client', case when v_client.id is null then null else
                jsonb_build_object('id', v_client.id, 'nom', v_client.nom, 'adresse', v_client.adresse) end,
      'mois', v_debut, 'projets', to_jsonb(array(select distinct unnest(p_projets) order by 1)),
      'tva', jsonb_build_object('regime', v_regime, 'territoire', v_territoire, 'pays', v_pays, 'taux', v_taux,
                                'mention', v_mention, 'criteres', v_criteres),
      'essai', v_essai, 'temps', v_temps)::text));
end
$$;

-- 5. Déclencheurs --------------------------------------------------------------------------------------------------
-- 5a. Projets : mode et tarif modifiés uniquement par les fonctions Finance ; historique des tarifs en ajout seul.
create or replace function public.projets_finance_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := coalesce(current_setting('sgi.fin_operation', true), '');
  v_n integer;
begin
  if tg_op = 'INSERT' then
    if new.mode_facturation is not null or new.tarif_vente_ht is not null or new.tarif_reference is not null
       or new.tarif_date_effet is not null or new.tarif_confirme_par is not null or new.tarif_confirme_par_nom is not null
       or new.tarif_confirme_le is not null or new.tarif_historique is distinct from '[]'::jsonb then
      raise exception 'Mode et tarif de facturation : définis ensuite par l''écran Finance (administrateur).';
    end if;
    return new;
  end if;
  if new.mode_facturation is distinct from old.mode_facturation
     and (public.appel_utilisateur() or v_op <> 'mode') then
    raise exception 'Le mode de facturation se définit uniquement par l''écran Finance (administrateur).';
  end if;
  if (new.tarif_vente_ht, new.tarif_reference, new.tarif_date_effet, new.tarif_confirme_par, new.tarif_confirme_par_nom,
      new.tarif_confirme_le, new.tarif_historique)
     is distinct from (old.tarif_vente_ht, old.tarif_reference, old.tarif_date_effet, old.tarif_confirme_par,
      old.tarif_confirme_par_nom, old.tarif_confirme_le, old.tarif_historique) then
    if public.appel_utilisateur() or v_op <> 'tarif' then
      raise exception 'Le tarif de vente se confirme uniquement par l''écran Finance (administrateur), avec une date d''effet.';
    end if;
    -- Historique : les événements existants restent identiques, un seul est ajouté.
    v_n := jsonb_array_length(old.tarif_historique);
    if jsonb_array_length(new.tarif_historique) <> v_n + 1
       or coalesce((select jsonb_agg(e order by o) from jsonb_array_elements(new.tarif_historique) with ordinality x(e, o)
                     where o <= v_n), '[]'::jsonb) is distinct from old.tarif_historique then
      raise exception 'Historique des tarifs : ajout seul (aucun événement modifié ni supprimé).';
    end if;
  end if;
  return new;
end
$$;
drop trigger if exists projets_finance_controle on public.projets;
create trigger projets_finance_controle before insert or update on public.projets
  for each row execute function public.projets_finance_controle();

-- 5b. Factures : naissance par l'émission seulement ; contenu figé ; suivi (PDF, envoi, règlement) par les fonctions
--     Finance, avec un événement d'historique ajouté par la base ; aucune correction par changement de statut.
create or replace function public.factures_finance_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := coalesce(current_setting('sgi.fin_operation', true), '');
  v_evt jsonb := nullif(coalesce(current_setting('sgi.fin_evenement', true), ''), '')::jsonb;
  v_pdf boolean;
  v_suivi boolean;
begin
  if public.appel_utilisateur() then
    raise exception 'Factures : écriture directe interdite ; passez par l''écran Finance.';
  end if;
  if tg_op = 'INSERT' then
    if v_op <> 'emission' or v_evt is null then
      raise exception 'Une facture naît uniquement de l''émission (écran Finance).';
    end if;
    if new.statut <> 'emise' or new.numero is null or new.instantane_emission is null or new.cle_emission is null
       or new.historique is distinct from '[]'::jsonb then
      raise exception 'Émission incomplète : facture refusée.';
    end if;
    new.historique := jsonb_build_array(v_evt || jsonb_build_object('le', now()));
    return new;
  end if;

  if new.historique is distinct from old.historique then
    raise exception 'Historique de la facture : alimenté par la base seulement.';
  end if;
  if (new.id, new.client_id, new.numero, new.date_emission, new.date_echeance, new.periode_debut, new.periode_fin,
      new.total_ht, new.tva, new.total_ttc, new.regime_tva, new.territoire_tva, new.pays_tva, new.taux_tva,
      new.mention_tva, new.criteres_tva, new.essai, new.instantane_emission, new.emise_par, new.emise_par_nom,
      new.emise_le, new.cle_emission, new.empreinte_apercu, new.created_at)
     is distinct from
     (old.id, old.client_id, old.numero, old.date_emission, old.date_echeance, old.periode_debut, old.periode_fin,
      old.total_ht, old.tva, old.total_ttc, old.regime_tva, old.territoire_tva, old.pays_tva, old.taux_tva,
      old.mention_tva, old.criteres_tva, old.essai, old.instantane_emission, old.emise_par, old.emise_par_nom,
      old.emise_le, old.cle_emission, old.empreinte_apercu, old.created_at) then
    raise exception 'Facture émise : son contenu ne se modifie jamais. Aucune erreur ne se corrige par un changement de statut.';
  end if;
  v_pdf := (new.pdf_statut, new.pdf_chemin, new.pdf_empreinte, new.pdf_taille, new.pdf_archive_le, new.pdf_erreur)
           is distinct from (old.pdf_statut, old.pdf_chemin, old.pdf_empreinte, old.pdf_taille, old.pdf_archive_le, old.pdf_erreur);
  v_suivi := (new.statut, new.date_envoi, new.date_reglement, new.mode_reglement, new.reference_reglement,
              new.reglement_declare_par, new.reglement_declare_par_nom, new.reglement_declare_le)
             is distinct from (old.statut, old.date_envoi, old.date_reglement, old.mode_reglement, old.reference_reglement,
              old.reglement_declare_par, old.reglement_declare_par_nom, old.reglement_declare_le);
  if not v_pdf and not v_suivi then
    return new;
  end if;
  if v_evt is null then
    raise exception 'Facture : modification réservée à l''écran Finance.';
  end if;
  if v_pdf then
    if v_op <> 'pdf' or v_suivi then
      raise exception 'Facture : le PDF s''enregistre uniquement par l''archivage.';
    end if;
    if old.pdf_statut = 'disponible' then
      raise exception 'PDF archivé : il ne se remplace pas.';
    end if;
  else
    if v_op = 'envoi' and old.statut = 'emise' and new.statut = 'envoyee' and new.date_envoi is not null
       and old.pdf_statut = 'disponible'
       and (new.date_reglement, new.mode_reglement, new.reglement_declare_par) is not distinct from
           (old.date_reglement, old.mode_reglement, old.reglement_declare_par) then
      null;
    elsif v_op = 'reglement' and old.statut = 'envoyee' and new.statut = 'payee' and new.date_reglement is not null
          and new.mode_reglement is not null and new.date_envoi is not distinct from old.date_envoi then
      null;
    elsif v_op = 'correction_reglement' and old.statut = 'payee' and new.date_envoi is not distinct from old.date_envoi
          and ((new.statut = 'payee' and new.date_reglement is not null and new.mode_reglement is not null)
               or (new.statut = 'envoyee' and new.date_reglement is null and new.mode_reglement is null
                   and new.reference_reglement is null)) then
      null;
    else
      raise exception 'Changement de statut interdit : % → %.', old.statut, new.statut;
    end if;
  end if;
  new.historique := old.historique || jsonb_build_array(v_evt || jsonb_build_object('le', now()));
  return new;
end
$$;
drop trigger if exists factures_finance_controle on public.factures;
create trigger factures_finance_controle before insert or update on public.factures
  for each row execute function public.factures_finance_controle();

-- Suppression : jamais (règle du module RH conservée) ; seule exception, le nettoyage des factures d'ESSAI.
create or replace function public.factures_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.essai and not public.appel_utilisateur()
     and coalesce(current_setting('sgi.fin_operation', true), '') = 'nettoyage_essais' then
    return old;
  end if;
  raise exception 'Suppression refusée : une facture ne se supprime jamais (règle de gestion de SG Ingénierie).';
end
$$;

-- 5c. Temps : taux et montant posés uniquement à l'émission, avec le rattachement ; figés ensuite.
create or replace function public.temps_finance_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.taux_facture is not null or new.montant_facture_ht is not null then
      raise exception 'Taux facturé : posé uniquement à l''émission d''une facture.';
    end if;
    return new;
  end if;
  if (new.facture_id, new.taux_facture, new.montant_facture_ht)
     is not distinct from (old.facture_id, old.taux_facture, old.montant_facture_ht) then
    return new;
  end if;
  if old.facture_id is null and new.facture_id is not null
     and coalesce(current_setting('sgi.fin_operation', true), '') = 'emission'
     and new.facture_id::text = coalesce(current_setting('sgi.fin_facture', true), '')
     and new.taux_facture > 0 and new.montant_facture_ht = round(new.heures * new.taux_facture, 2) then
    return new;
  end if;
  raise exception 'Un temps est facturé uniquement par l''émission d''une facture (tarif et montant figés à ce moment).';
end
$$;
drop trigger if exists temps_finance_controle on public.temps;
create trigger temps_finance_controle before insert or update on public.temps
  for each row execute function public.temps_finance_controle();

-- 5d. Règles des temps (module RH) reprises À L'IDENTIQUE, avec une seule exception ajoutée : le nettoyage des
--     factures d'ESSAI supprime les temps qu'elles portent (projet d'ESSAI, clé secrète, contexte Finance).
create or replace function public.temps_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auteur uuid := nullif(current_setting('sgi.rh_auteur', true), '')::uuid;
  v_action text := nullif(current_setting('sgi.rh_action', true), '');
  v_motif text := nullif(btrim(coalesce(current_setting('sgi.rh_motif', true), '')), '');
  v_role text;
  v_collab_auteur uuid;
  v_nom text;
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  v_sortie date;
  v_total numeric;
  v_statut_projet text;
  v_contenu boolean;
  v_evenements jsonb := '[]'::jsonb;
  v_hors_app boolean;
  v_essai boolean;
begin
  if public.appel_utilisateur() then
    raise exception 'Temps : écriture directe interdite ; passez par l''application.';
  end if;
  v_hors_app := v_auteur is null;
  if not v_hors_app then
    select role, collaborateur_id, coalesce(nullif(nom, ''), email) into v_role, v_collab_auteur, v_nom
      from public.profiles where id = v_auteur;
    if v_role is null then
      raise exception 'Temps : auteur inconnu.';
    end if;
  else
    v_nom := 'Hors application (tableau de bord ou clé secrète)';
  end if;

  -- Suppression -----------------------------------------------------------------------------------------------
  if tg_op = 'DELETE' then
    select coalesce(d.essai, false) into v_essai
      from public.projets p left join public.devis d on d.id = p.devis_id where p.id = old.projet_id;
    if old.facture_id is not null then
      -- Seule exception (module Finance) : nettoyage des factures d'ESSAI (clé secrète, projet d'ESSAI).
      if v_hors_app and coalesce(v_essai, false)
         and coalesce(current_setting('sgi.fin_operation', true), '') = 'nettoyage_essais'
         and exists (select 1 from public.factures f where f.id = old.facture_id and f.essai) then
        return old;
      end if;
      raise exception 'Temps facturé : suppression impossible.';
    end if;
    if v_hors_app and coalesce(v_essai, false) then
      return old;   -- nettoyage des essais (temps sur un projet d'ESSAI), clé secrète
    end if;
    if old.statut <> 'brouillon' then
      raise exception 'Seul un temps en brouillon se supprime (statut : %).', old.statut;
    end if;
    if exists (select 1 from jsonb_array_elements(old.historique) e
                where e ->> 'action' in ('validation', 'reouverture', 'anterieur_au_module_rh')) then
      raise exception 'Ce temps a déjà été validé une fois : corrigez-le au lieu de le supprimer (l''historique est conservé).';
    end if;
    if not v_hors_app and v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
      raise exception 'Vous ne pouvez supprimer que vos propres temps.';
    end if;
    return old;
  end if;

  -- Création ----------------------------------------------------------------------------------------------------
  if tg_op = 'INSERT' then
    if new.statut <> 'brouillon' or new.facture_id is not null or new.valide_par is not null
       or new.valide_par_nom is not null or new.valide_le is not null then
      raise exception 'Un temps est créé en brouillon, non validé et non facturé.';
    end if;
    if new.historique is distinct from '[]'::jsonb then
      raise exception 'Historique : alimenté par la base seulement.';
    end if;
    if not v_hors_app and v_role <> 'admin' then
      if v_collab_auteur is null then
        raise exception 'Votre compte n''est rattaché à aucune fiche collaborateur : saisie impossible.';
      end if;
      if new.collaborateur_id <> v_collab_auteur then
        raise exception 'Vous ne pouvez saisir que vos propres temps.';
      end if;
    end if;
    new.saisi_par := v_auteur;
    new.saisi_par_nom := v_nom;
    new.saisi_le := now();
    v_contenu := true;
    v_evenements := jsonb_build_array(jsonb_build_object('action', 'saisie', 'le', now(), 'auteur', v_auteur,
      'auteur_nom', v_nom, 'pour_collaborateur', new.collaborateur_id, 'motif', null));
  else
  -- Modification ------------------------------------------------------------------------------------------------
    if old.facture_id is not null then
      raise exception 'Temps facturé : plus aucune modification possible.';
    end if;
    if new.historique is distinct from old.historique then
      raise exception 'Historique : alimenté par la base seulement, ni modifiable ni effaçable.';
    end if;
    if (new.id, new.collaborateur_id, new.saisi_par, new.saisi_par_nom, new.saisi_le, new.created_at)
       is distinct from (old.id, old.collaborateur_id, old.saisi_par, old.saisi_par_nom, old.saisi_le, old.created_at) then
      raise exception 'Le collaborateur, l''auteur de la saisie et la date de création d''un temps ne changent pas.';
    end if;
    if (new.valide_par, new.valide_par_nom, new.valide_le) is distinct from (old.valide_par, old.valide_par_nom, old.valide_le) then
      raise exception 'La validation est enregistrée par la base seulement.';
    end if;
    v_contenu := (new.projet_id, new.date_saisie, new.heures, new.commentaire, new.motif_derogation)
                 is distinct from (old.projet_id, old.date_saisie, old.heures, old.commentaire, old.motif_derogation);

    -- Facturation (futur module Finance, clé secrète) : une seule fois, sur un temps validé, sans autre changement.
    if new.facture_id is not null then
      if not v_hors_app or old.statut <> 'valide' or new.statut <> 'valide' or v_contenu then
        raise exception 'Un temps est rattaché à une facture une seule fois, validé et inchangé, par le module Finance.';
      end if;
      new.historique := old.historique || jsonb_build_array(jsonb_build_object('action', 'facturation', 'le', now(),
        'auteur', null, 'auteur_nom', v_nom, 'facture', new.facture_id, 'motif', null));
      return new;
    end if;

    if new.statut is distinct from old.statut or v_action = 'attester' then
      if v_contenu then
        raise exception 'Changer le statut et le contenu d''un temps en même temps est interdit.';
      end if;
      if v_hors_app then
        raise exception 'Les changements de statut passent par l''application (auteur identifié).';
      end if;
      if old.statut = 'brouillon' and new.statut = 'soumis' then
        if v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
          raise exception 'Vous ne pouvez soumettre que vos propres temps.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'soumission', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', null));
      elsif old.statut = 'soumis' and new.statut = 'brouillon' then
        if v_collab_auteur is not distinct from old.collaborateur_id and coalesce(v_action, 'retirer') = 'retirer' then
          v_evenements := jsonb_build_array(jsonb_build_object('action', 'retrait', 'le', now(), 'auteur', v_auteur,
            'auteur_nom', v_nom, 'motif', v_motif));
        elsif public.rh_est_valideur(v_role, v_collab_auteur, old.collaborateur_id) then
          if v_motif is null then
            raise exception 'Renvoi : un motif est obligatoire.';
          end if;
          v_evenements := jsonb_build_array(jsonb_build_object('action', 'renvoi', 'le', now(), 'auteur', v_auteur,
            'auteur_nom', v_nom, 'motif', v_motif));
        else
          raise exception 'Seul le responsable du collaborateur (ou l''administrateur) peut renvoyer ce temps.';
        end if;
      elsif old.statut = 'soumis' and new.statut = 'valide' then
        if v_collab_auteur is not distinct from old.collaborateur_id then
          raise exception 'Personne ne valide ses propres temps.';
        end if;
        if not public.rh_est_valideur(v_role, v_collab_auteur, old.collaborateur_id) then
          raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) valide ce temps.';
        end if;
        new.valide_par := v_auteur;
        new.valide_par_nom := v_nom;
        new.valide_le := now();
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'validation', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', null));
      elsif old.statut = 'valide' and new.statut = 'brouillon' then
        if v_role <> 'admin' then
          raise exception 'Seul l''administrateur rouvre un temps validé.';
        end if;
        if v_motif is null then
          raise exception 'Réouverture : un motif de correction est obligatoire.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'reouverture', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', v_motif,
          'validation_precedente', jsonb_build_object('valide_par', old.valide_par, 'valide_par_nom', old.valide_par_nom,
                                                      'valide_le', old.valide_le)));
        new.valide_par := null;
        new.valide_par_nom := null;
        new.valide_le := null;
      elsif old.statut = 'soumis' and new.statut = 'soumis' and v_action = 'attester' then
        -- Attestation de l'intéressé : information distincte, pas une validation ; le statut reste « soumis ».
        if v_collab_auteur is distinct from old.collaborateur_id then
          raise exception 'Seul le collaborateur concerné atteste ses propres temps.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'attestation_interesse', 'le', now(),
          'auteur', v_auteur, 'auteur_nom', v_nom, 'motif', v_motif));
      else
        raise exception 'Changement de statut interdit : % → %.', old.statut, new.statut;
      end if;
    elsif v_contenu then
      if old.statut <> 'brouillon' then
        raise exception 'Seul un temps en brouillon se corrige (statut : %).', old.statut;
      end if;
      if not v_hors_app and v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
        raise exception 'Vous ne pouvez corriger que vos propres temps.';
      end if;
      v_evenements := jsonb_build_array(jsonb_build_object('action', 'correction', 'le', now(), 'auteur', v_auteur,
        'auteur_nom', v_nom, 'motif', null));
    else
      return new;   -- aucune modification réelle
    end if;
  end if;

  -- Contrôles de contenu (création ou correction) ------------------------------------------------------------------
  if v_contenu then
    -- Verrou sur la fiche : les saisies simultanées d'une même personne passent l'une après l'autre (cumuls exacts).
    select date_sortie into v_sortie from public.collaborateurs where id = new.collaborateur_id for update;
    if not found then
      raise exception 'Fiche collaborateur introuvable.';
    end if;
    if new.date_saisie > v_aujourdhui then
      raise exception 'Date future refusée (%).', to_char(new.date_saisie, 'DD/MM/YYYY');
    end if;
    if v_sortie is not null and new.date_saisie > v_sortie then
      raise exception 'Date refusée : le collaborateur a quitté l''entreprise le % (régularisation possible pour les journées antérieures).',
        to_char(v_sortie, 'DD/MM/YYYY');
    end if;
    if tg_op = 'INSERT' or new.projet_id is distinct from old.projet_id then
      select statut into v_statut_projet from public.projets where id = new.projet_id;
      if v_statut_projet is distinct from 'en_cours' then
        raise exception 'Projet fermé à la saisie (statut : %).', coalesce(v_statut_projet, 'introuvable');
      end if;
    end if;
    select coalesce(sum(heures), 0) + new.heures into v_total
      from public.temps where collaborateur_id = new.collaborateur_id and date_saisie = new.date_saisie
       and id is distinct from new.id;
    if v_total > 24 then
      raise exception 'Refusé : % h le % pour ce collaborateur ; le plafond absolu est de 24 h par jour.',
        replace(v_total::text, '.', ','), to_char(new.date_saisie, 'DD/MM/YYYY');
    end if;
    if v_total > 12 or new.date_saisie < v_aujourdhui - 31 then
      if not v_hors_app and v_role <> 'admin' then
        raise exception '%', case when v_total > 12
          then 'Au-delà de 12 h par jour (' || replace(v_total::text, '.', ',') || ' h), seul l''administrateur peut enregistrer, avec un motif.'
          else 'Saisie au-delà de 31 jours : seul l''administrateur peut enregistrer, avec un motif.' end;
      end if;
      if nullif(btrim(coalesce(new.motif_derogation, '')), '') is null then
        raise exception 'Dérogation : un motif est obligatoire (au-delà de 12 h par jour ou de 31 jours).';
      end if;
      v_evenements := v_evenements || jsonb_build_array(jsonb_build_object('action', 'derogation', 'le', now(),
        'auteur', v_auteur, 'auteur_nom', v_nom, 'motif', new.motif_derogation,
        'cumul_jour', v_total, 'anciennete_jours', v_aujourdhui - new.date_saisie));
    end if;
  end if;

  new.historique := case when tg_op = 'INSERT' then '[]'::jsonb else old.historique end || v_evenements;
  return new;
end
$$;

-- 6. Fonctions de service (clé secrète seulement, appelées par les actions serveur après exigerAdmin) ----------------
-- 6a. Mode de facturation d'un projet : figé dès qu'un temps du projet est facturé.
create or replace function public.finance_definir_mode(p_auteur uuid, p_projet uuid, p_mode text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v_projet public.projets;
begin
  if p_mode is null or p_mode not in ('temps_passe', 'forfait', 'non_facturable') then
    raise exception 'Mode de facturation inconnu.';
  end if;
  select * into v_projet from public.projets where id = p_projet for update;
  if not found then
    raise exception 'Projet introuvable.';
  end if;
  if v_projet.mode_facturation is not distinct from p_mode then
    return;
  end if;
  if exists (select 1 from public.temps where projet_id = p_projet and facture_id is not null) then
    raise exception 'Mode figé : des temps de ce projet sont déjà facturés.';
  end if;
  perform public.finance_contexte('mode', null, null);
  update public.projets set mode_facturation = p_mode where id = p_projet;
  perform public.finance_fin_contexte();
end
$$;

-- 6b. Nouveau tarif à date d'effet. Verrou du projet : un changement de tarif et une émission ne se croisent
--     jamais (l'émission verrouille aussi les projets). Les temps concernés sont confirmés par leur empreinte.
create or replace function public.finance_confirmer_tarif(p_auteur uuid, p_projet uuid, p_tarif numeric, p_date_effet date,
                                                          p_reference text, p_empreinte_temps text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v_projet public.projets;
  v_derniere date;
  v_concernes jsonb;
  v_evt jsonb;
begin
  select * into v_projet from public.projets where id = p_projet for update;
  if not found then
    raise exception 'Projet introuvable.';
  end if;
  if p_tarif is null or p_tarif <= 0 then
    raise exception 'Tarif refusé : le tarif horaire de vente doit être strictement positif.';
  end if;
  if p_tarif <> round(p_tarif, 2) then
    raise exception 'Tarif refusé : 2 décimales au plus.';
  end if;
  if p_date_effet is null then
    raise exception 'Date d''effet obligatoire.';
  end if;
  if coalesce(btrim(p_reference), '') = '' then
    raise exception 'Référence du contrat obligatoire (contrat, devis ou avenant).';
  end if;
  select max(date_effet) into v_derniere from public.finance_periodes_actives(v_projet.tarif_historique);
  if v_derniere is not null and p_date_effet <= v_derniere then
    raise exception 'Date d''effet refusée : elle doit être postérieure au % (date d''effet du dernier tarif confirmé). Pour une erreur de saisie sur ce dernier tarif, utilisez « Corriger le dernier tarif ».',
      to_char(v_derniere, 'DD/MM/YYYY');
  end if;
  if exists (select 1 from public.temps where projet_id = p_projet and date_saisie >= p_date_effet and facture_id is not null) then
    raise exception 'Date d''effet refusée : des temps travaillés depuis le % sont déjà facturés.', to_char(p_date_effet, 'DD/MM/YYYY');
  end if;
  perform 1 from public.temps where projet_id = p_projet and date_saisie >= p_date_effet and facture_id is null
   order by id for share;
  v_concernes := public.finance_temps_concernes(p_projet, p_date_effet);
  if p_empreinte_temps is distinct from v_concernes ->> 'empreinte' then
    raise exception 'Confirmation périmée : les temps concernés par ce tarif ont changé (identité, date ou heures). Affichez la liste actualisée et confirmez à nouveau.';
  end if;
  v_evt := jsonb_build_object('type', 'periode', 'id', gen_random_uuid(), 'tarif', p_tarif, 'date_effet', p_date_effet,
    'reference', btrim(p_reference), 'par', p_auteur, 'par_nom', v_nom, 'le', now(),
    'temps_concernes', v_concernes -> 'nb', 'heures_concernees', v_concernes -> 'heures',
    'empreinte_temps', v_concernes ->> 'empreinte');
  perform public.finance_contexte('tarif', null, null);
  update public.projets
     set tarif_historique = tarif_historique || jsonb_build_array(v_evt), tarif_vente_ht = p_tarif,
         tarif_reference = btrim(p_reference), tarif_date_effet = p_date_effet, tarif_confirme_par = p_auteur,
         tarif_confirme_par_nom = v_nom, tarif_confirme_le = now()
   where id = p_projet;
  perform public.finance_fin_contexte();
  return v_evt;
end
$$;

-- 6c. Correction d'une erreur de saisie sur le DERNIER tarif : nouvel événement qui désigne la période remplacée
--     (l'ancien reste intact) ; même date d'effet ; refusée si un temps a déjà été facturé à ce tarif.
create or replace function public.finance_corriger_tarif(p_auteur uuid, p_projet uuid, p_periode_id text, p_tarif numeric,
                                                         p_reference text, p_motif text, p_empreinte_temps text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v_projet public.projets;
  v_dernier record;
  v_concernes jsonb;
  v_evt jsonb;
begin
  select * into v_projet from public.projets where id = p_projet for update;
  if not found then
    raise exception 'Projet introuvable.';
  end if;
  select * into v_dernier from public.finance_periodes_actives(v_projet.tarif_historique) order by date_effet desc limit 1;
  if v_dernier.id is null or v_dernier.id is distinct from p_periode_id then
    raise exception 'Seul le dernier tarif confirmé peut être corrigé.';
  end if;
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Correction : un motif est obligatoire (5 caractères au moins).';
  end if;
  if p_tarif is null or p_tarif <= 0 then
    raise exception 'Tarif refusé : le tarif horaire de vente doit être strictement positif.';
  end if;
  if p_tarif <> round(p_tarif, 2) then
    raise exception 'Tarif refusé : 2 décimales au plus.';
  end if;
  if coalesce(btrim(p_reference), '') = '' then
    raise exception 'Référence du contrat obligatoire (contrat, devis ou avenant).';
  end if;
  if exists (select 1 from public.temps where projet_id = p_projet and date_saisie >= v_dernier.date_effet
                                          and facture_id is not null) then
    raise exception 'Correction refusée : des temps sont déjà facturés à ce tarif. Un changement passe par un nouveau tarif à une date d''effet ultérieure.';
  end if;
  perform 1 from public.temps where projet_id = p_projet and date_saisie >= v_dernier.date_effet and facture_id is null
   order by id for share;
  v_concernes := public.finance_temps_concernes(p_projet, v_dernier.date_effet);
  if p_empreinte_temps is distinct from v_concernes ->> 'empreinte' then
    raise exception 'Confirmation périmée : les temps concernés par ce tarif ont changé (identité, date ou heures). Affichez la liste actualisée et confirmez à nouveau.';
  end if;
  v_evt := jsonb_build_object('type', 'correction', 'id', gen_random_uuid(), 'remplace', v_dernier.id, 'tarif', p_tarif,
    'date_effet', v_dernier.date_effet, 'reference', btrim(p_reference), 'motif', btrim(p_motif), 'par', p_auteur,
    'par_nom', v_nom, 'le', now(), 'temps_concernes', v_concernes -> 'nb', 'heures_concernees', v_concernes -> 'heures',
    'empreinte_temps', v_concernes ->> 'empreinte');
  perform public.finance_contexte('tarif', null, null);
  update public.projets
     set tarif_historique = tarif_historique || jsonb_build_array(v_evt), tarif_vente_ht = p_tarif,
         tarif_reference = btrim(p_reference), tarif_confirme_par = p_auteur, tarif_confirme_par_nom = v_nom,
         tarif_confirme_le = now()
   where id = p_projet;
  perform public.finance_fin_contexte();
  return v_evt;
end
$$;

-- 6d. Émission. Rejouée avec la même clé (double clic, coupure réseau) : renvoie la même facture, sans nouveau numéro.
--     Ordre des verrous : clé d'émission, projets (partagé), temps (exclusif) — le même ordre que les tarifs.
create or replace function public.finance_emettre_facture(p_auteur uuid, p_cle_emission uuid, p_client uuid, p_mois date,
  p_projets uuid[], p_tva jsonb, p_empreinte text, p_emetteur jsonb, p_conditions jsonb, p_gabarit text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v_existante public.factures;
  v_calc jsonb;
  v_erreur text;
  v_essai boolean;
  v_numero text;
  v_date date := (now() at time zone 'America/Martinique')::date;
  v_echeance date;
  v_id uuid;
  v_t jsonb;
  v_nb integer := 0;
  v_somme numeric;
begin
  if p_cle_emission is null then
    raise exception 'Émission : clé d''émission manquante.';
  end if;
  if coalesce(btrim(p_gabarit), '') = '' then
    raise exception 'Émission : gabarit du PDF manquant.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('finance_emission:' || p_cle_emission::text, 0));
  select * into v_existante from public.factures where cle_emission = p_cle_emission;
  if found then
    if v_existante.empreinte_apercu is distinct from p_empreinte then
      raise exception 'Cette clé d''émission a déjà servi pour une autre sélection.';
    end if;
    return jsonb_build_object('facture_id', v_existante.id, 'numero', v_existante.numero, 'deja_emise', true);
  end if;

  perform 1 from public.projets where id = any(p_projets) order by id for share;
  perform 1 from public.temps t join public.projets p on p.id = t.projet_id
   where t.projet_id = any(p_projets) and p.client_id = p_client and t.statut = 'valide' and t.facture_id is null
     and t.date_saisie between date_trunc('month', p_mois)::date
                           and (date_trunc('month', p_mois) + interval '1 month - 1 day')::date
   order by t.id for update of t;

  v_calc := public.finance_calculer(p_client, p_mois, p_projets, p_tva);
  if jsonb_array_length(v_calc -> 'blocages') > 0 then
    select string_agg(b, ' ') into v_erreur from jsonb_array_elements_text(v_calc -> 'blocages') b;
    raise exception 'Émission impossible : %', v_erreur;
  end if;
  if v_calc ->> 'empreinte' is distinct from p_empreinte then
    raise exception 'Aperçu périmé : les temps, les tarifs ou le traitement ont changé depuis l''aperçu. Affichez l''aperçu actualisé et confirmez à nouveau ; rien n''a été émis.';
  end if;
  v_essai := (v_calc ->> 'essai')::boolean;
  v_erreur := public.finance_controle_emetteur(p_emetteur, p_conditions, v_essai);
  if v_erreur is not null then
    raise exception 'Émission impossible : %.', v_erreur;
  end if;

  v_numero := public.attribuer_numero(case when v_essai then 'essai_facture' else 'facture' end,
                                      case when v_essai then 'ESSAI-FAC' else 'FAC' end);
  v_echeance := v_date + (p_conditions ->> 'delai_paiement_jours')::integer;
  v_id := gen_random_uuid();
  perform public.finance_contexte('emission', jsonb_build_object('action', 'emission', 'auteur', p_auteur,
    'auteur_nom', v_nom, 'numero', v_numero), v_id);
  insert into public.factures (id, client_id, numero, date_emission, date_echeance, periode_debut, periode_fin,
                               total_ht, tva, total_ttc, statut, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva,
                               criteres_tva, essai, instantane_emission, emise_par, emise_par_nom, emise_le, pdf_statut,
                               cle_emission, empreinte_apercu)
  values (v_id, p_client, v_numero, v_date, v_echeance, (v_calc ->> 'periode_debut')::date, (v_calc ->> 'periode_fin')::date,
          (v_calc -> 'totaux' ->> 'total_ht')::numeric, (v_calc -> 'totaux' ->> 'tva')::numeric,
          (v_calc -> 'totaux' ->> 'total_ttc')::numeric, 'emise', v_calc -> 'tva' ->> 'regime',
          v_calc -> 'tva' ->> 'territoire', v_calc -> 'tva' ->> 'pays', (v_calc -> 'tva' ->> 'taux')::numeric,
          v_calc -> 'tva' ->> 'mention', v_calc -> 'tva' -> 'criteres', v_essai,
          jsonb_build_object('version', 1, 'gabarit', p_gabarit, 'essai', v_essai, 'numero', v_numero,
            'date_emission', v_date, 'date_echeance', v_echeance,
            'periode', jsonb_build_object('mois', v_calc ->> 'mois', 'debut', v_calc ->> 'periode_debut',
                                          'fin', v_calc ->> 'periode_fin'),
            'emetteur', p_emetteur, 'conditions', p_conditions, 'client', v_calc -> 'client',
            'projets', v_calc -> 'projets', 'lignes', v_calc -> 'lignes', 'temps', v_calc -> 'temps',
            'totaux', v_calc -> 'totaux', 'tva', v_calc -> 'tva', 'emise_par_nom', v_nom),
          p_auteur, v_nom, now(), 'a_generer', p_cle_emission, p_empreinte);
  for v_t in select * from jsonb_array_elements(v_calc -> 'temps') loop
    update public.temps
       set facture_id = v_id, taux_facture = (v_t ->> 'tarif')::numeric, montant_facture_ht = (v_t ->> 'montant_ht')::numeric
     where id = (v_t ->> 'id')::uuid and statut = 'valide' and facture_id is null;
    if not found then
      raise exception 'Émission annulée : un temps a changé pendant l''émission ; rien n''a été émis.';
    end if;
    v_nb := v_nb + 1;
  end loop;
  select sum(montant_facture_ht) into v_somme from public.temps where facture_id = v_id;
  if v_somme is distinct from (v_calc -> 'totaux' ->> 'total_ht')::numeric or v_nb = 0 then
    raise exception 'Émission annulée : total des temps facturés incohérent ; rien n''a été émis.';
  end if;
  perform public.finance_fin_contexte();
  return jsonb_build_object('facture_id', v_id, 'numero', v_numero, 'deja_emise', false);
end
$$;

-- 6e. PDF : archivé une fois dans le bucket privé « factures » ; le fichier stocké fait foi (reprise : même numéro,
--     même instantané). Échec signalé sans rien perdre : nouvelle tentative possible.
create or replace function public.finance_enregistrer_pdf(p_facture uuid, p_chemin text, p_empreinte text, p_taille bigint)
returns void
language plpgsql
set search_path = public
as $$
declare
  v public.factures;
begin
  select * into v from public.factures where id = p_facture for update;
  if not found then
    raise exception 'Facture introuvable.';
  end if;
  if v.pdf_statut = 'disponible' then
    if v.pdf_empreinte = p_empreinte and v.pdf_chemin = p_chemin then
      return;
    end if;
    raise exception 'Un PDF différent est déjà archivé pour cette facture.';
  end if;
  if not exists (select 1 from storage.objects o
                  where o.bucket_id = 'factures' and o.name = p_chemin and (o.metadata ->> 'size')::bigint = p_taille) then
    raise exception 'PDF absent du stockage ou taille différente : non déclaré disponible.';
  end if;
  perform public.finance_contexte('pdf', jsonb_build_object('action', 'pdf_archive', 'empreinte', p_empreinte,
    'taille', p_taille), p_facture);
  update public.factures
     set pdf_statut = 'disponible', pdf_chemin = p_chemin, pdf_empreinte = p_empreinte, pdf_taille = p_taille,
         pdf_archive_le = now(), pdf_erreur = null
   where id = p_facture;
  perform public.finance_fin_contexte();
end
$$;

create or replace function public.finance_signaler_echec_pdf(p_facture uuid, p_erreur text)
returns void
language plpgsql
set search_path = public
as $$
begin
  if exists (select 1 from public.factures where id = p_facture and pdf_statut in ('a_generer', 'echec')) then
    perform public.finance_contexte('pdf', jsonb_build_object('action', 'pdf_echec',
      'erreur', left(coalesce(p_erreur, 'Erreur inconnue'), 500)), p_facture);
    update public.factures set pdf_statut = 'echec', pdf_erreur = left(coalesce(p_erreur, 'Erreur inconnue'), 500)
     where id = p_facture;
    perform public.finance_fin_contexte();
  end if;
end
$$;

-- 6f. Envoi DÉCLARÉ (aucun email n'est envoyé par l'application) : seulement quand le PDF est disponible.
create or replace function public.finance_declarer_envoi(p_auteur uuid, p_facture uuid, p_date_envoi timestamptz,
                                                         p_canal text, p_destinataire text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v public.factures;
begin
  select * into v from public.factures where id = p_facture for update;
  if not found then
    raise exception 'Facture introuvable.';
  end if;
  if v.statut <> 'emise' then
    raise exception 'Envoi déjà déclaré (statut : %).', v.statut;
  end if;
  if v.pdf_statut is distinct from 'disponible' then
    raise exception 'Envoi impossible : le PDF archivé de la facture n''est pas encore disponible.';
  end if;
  if p_canal is null or p_canal not in ('email', 'main_propre', 'courrier', 'plateforme', 'autre') then
    raise exception 'Canal d''envoi inconnu.';
  end if;
  if p_date_envoi is null or p_date_envoi > now() + interval '5 minutes' then
    raise exception 'Date d''envoi manquante ou future.';
  end if;
  if (p_date_envoi at time zone 'America/Martinique')::date < v.date_emission then
    raise exception 'Date d''envoi antérieure à l''émission.';
  end if;
  perform public.finance_contexte('envoi', jsonb_build_object('action', 'envoi_declare', 'auteur', p_auteur,
    'auteur_nom', v_nom, 'date_envoi', p_date_envoi, 'canal', p_canal, 'destinataire', nullif(btrim(p_destinataire), '')),
    p_facture);
  update public.factures set statut = 'envoyee', date_envoi = p_date_envoi where id = p_facture;
  perform public.finance_fin_contexte();
end
$$;

-- 6g. Règlement : INTÉGRAL seulement dans cette version (un paiement partiel n'est jamais enregistré).
create or replace function public.finance_enregistrer_reglement(p_auteur uuid, p_facture uuid, p_date date, p_mode text,
                                                                p_reference text, p_integral boolean)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v public.factures;
begin
  select * into v from public.factures where id = p_facture for update;
  if not found then
    raise exception 'Facture introuvable.';
  end if;
  if p_integral is not true then
    raise exception 'Paiement partiel non géré dans cette version : aucun règlement n''a été enregistré. Enregistrez le règlement seulement quand la totalité (% € TTC) a été reçue.',
      replace(v.total_ttc::text, '.', ',');
  end if;
  if v.statut = 'emise' then
    raise exception 'Déclarez d''abord l''envoi de la facture.';
  end if;
  if v.statut <> 'envoyee' then
    raise exception 'Règlement déjà enregistré : utilisez « Corriger la déclaration de règlement ».';
  end if;
  if p_mode is null or p_mode not in ('virement', 'cheque', 'especes', 'carte', 'autre') then
    raise exception 'Mode de règlement inconnu.';
  end if;
  if p_date is null or p_date > (now() at time zone 'America/Martinique')::date or p_date < v.date_emission then
    raise exception 'Date de règlement manquante, future ou antérieure à l''émission.';
  end if;
  perform public.finance_contexte('reglement', jsonb_build_object('action', 'reglement_integral', 'auteur', p_auteur,
    'auteur_nom', v_nom, 'date_reglement', p_date, 'mode', p_mode, 'reference', nullif(btrim(p_reference), ''),
    'montant_ttc', v.total_ttc), p_facture);
  update public.factures
     set statut = 'payee', date_reglement = p_date, mode_reglement = p_mode, reference_reglement = nullif(btrim(p_reference), ''),
         reglement_declare_par = p_auteur, reglement_declare_par_nom = v_nom, reglement_declare_le = now()
   where id = p_facture;
  perform public.finance_fin_contexte();
end
$$;

-- 6h. Correction d'une déclaration de règlement erronée : admin, motif obligatoire, valeurs précédentes conservées
--     dans l'historique ; la facture émise (contenu, montants, numéro) ne change pas.
create or replace function public.finance_corriger_reglement(p_auteur uuid, p_facture uuid, p_action text, p_date date,
                                                             p_mode text, p_reference text, p_motif text)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_nom text := public.verifier_auteur_finance(p_auteur);
  v public.factures;
  v_precedent jsonb;
begin
  select * into v from public.factures where id = p_facture for update;
  if not found then
    raise exception 'Facture introuvable.';
  end if;
  if v.statut <> 'payee' then
    raise exception 'Aucun règlement enregistré à corriger.';
  end if;
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Correction du règlement : un motif est obligatoire (5 caractères au moins).';
  end if;
  v_precedent := jsonb_build_object('date_reglement', v.date_reglement, 'mode', v.mode_reglement,
    'reference', v.reference_reglement, 'declare_par_nom', v.reglement_declare_par_nom, 'declare_le', v.reglement_declare_le);
  if p_action = 'annuler' then
    perform public.finance_contexte('correction_reglement', jsonb_build_object('action', 'reglement_annule',
      'auteur', p_auteur, 'auteur_nom', v_nom, 'motif', btrim(p_motif), 'precedent', v_precedent), p_facture);
    update public.factures
       set statut = 'envoyee', date_reglement = null, mode_reglement = null, reference_reglement = null,
           reglement_declare_par = null, reglement_declare_par_nom = null, reglement_declare_le = null
     where id = p_facture;
  elsif p_action = 'modifier' then
    if p_mode is null or p_mode not in ('virement', 'cheque', 'especes', 'carte', 'autre') then
      raise exception 'Mode de règlement inconnu.';
    end if;
    if p_date is null or p_date > (now() at time zone 'America/Martinique')::date or p_date < v.date_emission then
      raise exception 'Date de règlement manquante, future ou antérieure à l''émission.';
    end if;
    perform public.finance_contexte('correction_reglement', jsonb_build_object('action', 'reglement_corrige',
      'auteur', p_auteur, 'auteur_nom', v_nom, 'motif', btrim(p_motif), 'precedent', v_precedent,
      'date_reglement', p_date, 'mode', p_mode, 'reference', nullif(btrim(p_reference), '')), p_facture);
    update public.factures
       set date_reglement = p_date, mode_reglement = p_mode, reference_reglement = nullif(btrim(p_reference), ''),
           reglement_declare_par = p_auteur, reglement_declare_par_nom = v_nom, reglement_declare_le = now()
     where id = p_facture;
  else
    raise exception 'Correction du règlement : action inconnue.';
  end if;
  perform public.finance_fin_contexte();
end
$$;

-- 6i. Nettoyage des factures d'ESSAI (clé secrète) : factures d'essai, temps qu'elles portent (projets d'ESSAI),
--     compteur essai_facture. Refuse tout si une donnée réelle y est liée. À appeler AVANT supprimer_essais_rh()
--     et supprimer_essais_commercial(). Renvoie les chemins des PDF à supprimer du bucket « factures ».
create or replace function public.supprimer_essais_finance()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_factures uuid[];
  v_chemins text[];
  v_nb_temps integer;
  v_nb_compteurs integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé aux essais autorisés (clé secrète)';
  end if;
  select coalesce(array_agg(id), '{}'), coalesce(array_agg(pdf_chemin) filter (where pdf_chemin is not null), '{}')
    into v_factures, v_chemins from public.factures where essai;
  if exists (select 1 from public.temps t
               left join public.projets p on p.id = t.projet_id left join public.devis d on d.id = p.devis_id
              where t.facture_id = any(v_factures) and not coalesce(d.essai, false))
     or exists (select 1 from public.factures f join public.clients c on c.id = f.client_id
                 where f.id = any(v_factures) and c.nom not like '[ESSAI]%')
     or exists (select 1 from public.relances where facture_id = any(v_factures)) then
    raise exception 'Nettoyage refusé : une donnée réelle est liée à une facture d''essai ; rien n''a été supprimé';
  end if;
  perform public.rh_fin_contexte();
  perform public.finance_contexte('nettoyage_essais', null, null);
  delete from public.temps where facture_id = any(v_factures);
  get diagnostics v_nb_temps = row_count;
  delete from public.factures where id = any(v_factures);
  delete from public.compteurs where cle ~ '^essai_facture_[0-9]{4}$';
  get diagnostics v_nb_compteurs = row_count;
  perform public.finance_fin_contexte();
  return jsonb_build_object('factures', cardinality(v_factures), 'temps', v_nb_temps, 'compteurs', v_nb_compteurs,
                            'pdf_chemins', to_jsonb(v_chemins));
end
$$;

-- Aucune de ces fonctions n'est appelable avec un jeton utilisateur ; aucune ne lit le coût interne (taux_horaire).
do $$
declare
  v_fonction text;
begin
  foreach v_fonction in array array[
    'attribuer_numero(text, text)', 'verifier_auteur_finance(uuid)', 'finance_contexte(text, jsonb, uuid)',
    'finance_fin_contexte()', 'finance_periodes_actives(jsonb)', 'finance_tarif_a_date(jsonb, date)',
    'finance_temps_concernes(uuid, date)', 'finance_controle_emetteur(jsonb, jsonb, boolean)',
    'finance_calculer(uuid, date, uuid[], jsonb)', 'finance_definir_mode(uuid, uuid, text)',
    'finance_confirmer_tarif(uuid, uuid, numeric, date, text, text)',
    'finance_corriger_tarif(uuid, uuid, text, numeric, text, text, text)',
    'finance_emettre_facture(uuid, uuid, uuid, date, uuid[], jsonb, text, jsonb, jsonb, text)',
    'finance_enregistrer_pdf(uuid, text, text, bigint)', 'finance_signaler_echec_pdf(uuid, text)',
    'finance_declarer_envoi(uuid, uuid, timestamptz, text, text)',
    'finance_enregistrer_reglement(uuid, uuid, date, text, text, boolean)',
    'finance_corriger_reglement(uuid, uuid, text, date, text, text, text)', 'supprimer_essais_finance()',
    'projets_finance_controle()', 'factures_finance_controle()', 'temps_finance_controle()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    if v_fonction not like '%_controle()' then
      execute format('grant execute on function public.%s to service_role', v_fonction);
    end if;
  end loop;
end
$$;

-- 7. Droits ---------------------------------------------------------------------------------------------------------
-- 7a. Factures : AUCUN droit pour les jetons utilisateurs (même admin) ; les écrans Finance lisent avec la clé
--     secrète après exigerAdmin. Règle RLS : lecture admin seulement (défense en profondeur), jamais d'écriture.
do $$
declare
  v_regle record;
begin
  for v_regle in select policyname from pg_policies where schemaname = 'public' and tablename = 'factures' loop
    execute format('drop policy if exists %I on public.factures', v_regle.policyname);
  end loop;
end
$$;
create policy "factures_lecture_admin" on public.factures for select to authenticated using ((select public.est_admin()));
revoke all on public.factures from anon, authenticated;

-- 7b. Projets et temps : lecture par colonnes nommées ; tarifs, historique des tarifs, taux et montants facturés exclus
--     (illisibles, non filtrables, non triables avec un jeton, « select=* » refusé).
revoke select on public.projets from authenticated;
grant select (id, nom, client_id, devis_id, statut, created_at, mode_facturation) on public.projets to authenticated;
revoke select on public.temps from authenticated;
grant select (id, collaborateur_id, projet_id, date_saisie, heures, commentaire, statut, facture_id, created_at,
              saisi_par, saisi_par_nom, saisi_le, valide_par, valide_par_nom, valide_le, motif_derogation, historique)
  on public.temps to authenticated;

-- 7c. Bucket privé d'archivage des factures : aucune règle → seule la clé secrète y accède.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('factures', 'factures', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];

-- 8. Contrôles finaux et autotest (annulé) ----------------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_admin uuid;
  v_emetteur constant jsonb := '{"raison_sociale":"[DÉMO] AUTOTEST","forme_juridique":"SAS","capital_social":"1",
    "adresse":"1 rue de l''Essai","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000",
    "immatriculation":"[DÉMO] RCS","tva_intracom":"[DÉMO]","validite_jours":"30","obligation_assurance":"non_requise"}';
  v_conditions constant jsonb := '{"delai_paiement_jours":"30","penalites_retard":"[DÉMO] pénalités",
    "indemnite_recouvrement":"[DÉMO] indemnité","escompte":"[DÉMO] escompte"}';
  v_tva constant jsonb := '{"regime":"taxable","territoire":"MQ","taux":8.5,
    "criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}';
  v_mois date := (date_trunc('month', (now() at time zone 'America/Martinique')::date) - interval '1 month')::date;
  v_prospect uuid;
  v_devis uuid;
  v_projet uuid;
  v_client uuid;
  v_a uuid;
  v_t uuid[];
  v_calc jsonb;
  v_res jsonb;
  v_res2 jsonb;
  v_facture uuid;
  v_evt jsonb;
  v_avant text;
  v_apres text;
begin
  -- Fonctions appelables avec un jeton : toujours exactement les 4 fonctions d'identité ; aucune pour le visiteur.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Finance : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Finance : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  -- Coût interne : toujours lu par aucune fonction.
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'Finance : fonction(s) lisant le coût interne taux_horaire : %', v_liste;
  end if;
  -- Données tarifaires : aucune colonne lisible, filtrable ni modifiable avec un jeton ; aucune vue ne les expose.
  select string_agg(table_name || '.' || column_name, ', ') into v_liste
    from information_schema.columns
   where table_schema = 'public'
     and ((table_name = 'projets' and column_name like 'tarif\_%')
          or (table_name = 'temps' and column_name in ('taux_facture', 'montant_facture_ht'))
          or table_name in ('factures'))
     and (has_column_privilege('authenticated', format('public.%I', table_name), column_name, 'select')
          or has_column_privilege('authenticated', format('public.%I', table_name), column_name, 'update')
          or has_column_privilege('authenticated', format('public.%I', table_name), column_name, 'insert')
          or has_column_privilege('anon', format('public.%I', table_name), column_name, 'select'));
  if v_liste is not null then
    raise exception 'Finance : colonnes accessibles avec un jeton : %', v_liste;
  end if;
  if has_table_privilege('authenticated', 'public.factures', 'select') or has_table_privilege('authenticated', 'public.factures', 'insert')
     or has_table_privilege('authenticated', 'public.factures', 'update') or has_table_privilege('authenticated', 'public.factures', 'delete')
     or has_table_privilege('authenticated', 'public.projets', 'select') or has_table_privilege('authenticated', 'public.temps', 'select') then
    raise exception 'Finance : droits de table trop larges (factures, projets ou temps)';
  end if;
  select string_agg(viewname, ', ') into v_liste from pg_views
   where schemaname = 'public' and (definition ilike '%tarif_%' or definition ilike '%taux_facture%'
                                    or definition ilike '%montant_facture%' or definition ilike '%factures%');
  if v_liste is not null then
    raise exception 'Finance : vue(s) exposant des données de facturation : %', v_liste;
  end if;
  -- Les anciennes lectures du site restent possibles (colonnes nommées).
  if not has_column_privilege('authenticated', 'public.temps', 'historique', 'select')
     or not has_column_privilege('authenticated', 'public.projets', 'devis_id', 'select') then
    raise exception 'Finance : lectures existantes des projets ou des temps cassées';
  end if;
  -- Toutes les règles passent par le contrôle de session active.
  select string_agg(tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'Finance : règles sans contrôle de session active : %', v_liste;
  end if;
  select count(*) into v_nb from pg_trigger
   where not tgisinternal and tgname in ('projets_finance_controle', 'factures_finance_controle', 'factures_avant_suppression',
                                         'temps_finance_controle', 'temps_controle', 'factures_controle_tva');
  if v_nb <> 6 then
    raise exception 'Finance : % déclencheurs sur 6 posés', v_nb;
  end if;
  if not exists (select 1 from storage.buckets where id = 'factures' and not public) then
    raise exception 'Finance : bucket privé « factures » absent';
  end if;

  -- Autotest complet, annulé à la fin (données d'ESSAI uniquement). Empreinte avant/après des tables touchées.
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(d::text, '|' order by d.id) from public.devis d), '')
          || coalesce((select string_agg(c.id || c.nom, '|' order by c.id) from public.collaborateurs c), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_avant;
  select id into v_admin from public.profiles where role = 'admin' order by created_at limit 1;
  if v_admin is null then
    raise exception 'Finance : aucun compte admin, autotest impossible';
  end if;
  begin
    -- Projet d'ESSAI issu d'un devis d'essai accepté (TVA Martinique 8,5 %).
    v_prospect := public.creer_prospect_essai('Autotest Finance', 'Autotest Finance SARL', '1 rue de l''Essai', '97200',
                                              'Fort-de-France', 'MQ');
    insert into public.devis (prospect_id) values (v_prospect) returning id into v_devis;
    insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values (v_devis, 'Régie', 1, 100);
    update public.devis set regime_tva = 'taxable', territoire_tva = 'MQ', taux_tva = 8.5, type_mission = 'conseil',
           criteres_tva = '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}' where id = v_devis;
    perform public.emettre_devis(v_devis, v_admin, v_emetteur, 'v1');
    update public.devis set pdf_statut = 'disponible', pdf_chemin = id || '/' || numero || '.pdf',
           pdf_empreinte = repeat('a', 64), pdf_taille = 1, pdf_archive_le = now() where id = v_devis;
    perform public.declarer_envoi_devis(v_devis, v_admin, now(), 'autre', null);
    perform public.decider_devis(v_devis, v_admin, 'accepte');
    select id, client_id into v_projet, v_client from public.projets where devis_id = v_devis;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Finance', 'A', 0) returning id into v_a;

    -- Sans mode ni tarif : non facturable, messages clairs.
    v_calc := public.finance_calculer(v_client, v_mois, array[v_projet], v_tva);
    if not (v_calc -> 'blocages') @> to_jsonb(array[format('Tarif de vente non confirmé pour le projet « %s » : facturation impossible.',
              (select nom from public.projets where id = v_projet))]) then
      raise exception 'AUTOTEST: projet sans tarif non bloqué (%)', v_calc -> 'blocages';
    end if;
    begin
      update public.projets set tarif_vente_ht = 50 where id = v_projet;
      raise exception 'AUTOTEST: tarif écrit hors des fonctions Finance';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.finance_definir_mode(v_admin, v_projet, 'temps_passe');

    -- Tarif 0 refusé ; période 1 (10,01 €) au 1er du mois ; période 2 (90 €) au 11.
    begin
      perform public.finance_confirmer_tarif(v_admin, v_projet, 0, v_mois, 'Contrat autotest',
        public.finance_temps_concernes(v_projet, v_mois) ->> 'empreinte');
      raise exception 'AUTOTEST: tarif nul accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.finance_confirmer_tarif(v_admin, v_projet, 10.01, v_mois, 'Contrat autotest',
      public.finance_temps_concernes(v_projet, v_mois) ->> 'empreinte');
    perform public.finance_confirmer_tarif(v_admin, v_projet, 90, v_mois + 10, 'Avenant autotest',
      public.finance_temps_concernes(v_projet, v_mois + 10) ->> 'empreinte');
    begin
      perform public.finance_confirmer_tarif(v_admin, v_projet, 95, v_mois + 5, 'Rétroactif',
        public.finance_temps_concernes(v_projet, v_mois + 5) ->> 'empreinte');
      raise exception 'AUTOTEST: date d''effet antérieure au dernier tarif acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Temps : 3 × 0,25 h à 10,01 € (2,5025 → 2,50 chacun ; écart -0,01) et 2,5 h à 90 € ; validés par l'admin.
    v_t := array[
      public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_mois + 1, 0.25, null, 'Autotest Finance'),
      public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_mois + 2, 0.25, null, 'Autotest Finance'),
      public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_mois + 3, 0.25, null, 'Autotest Finance'),
      public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_mois + 12, 2.5, null, 'Autotest Finance')];
    perform public.rh_changer_statut_temps(v_admin, v_t, 'soumettre', null);
    perform public.rh_changer_statut_temps(v_admin, v_t, 'valider', null);

    -- Correction du dernier tarif : la période remplacée reste dans l'historique et n'est plus appliquée.
    v_evt := (select e from public.projets p, jsonb_array_elements(p.tarif_historique) e
               where p.id = v_projet and e ->> 'tarif' = '90');
    begin
      perform public.finance_corriger_tarif(v_admin, v_projet, v_evt ->> 'id', 80, 'Avenant autotest', 'Erreur de saisie',
        'empreinte-perimee');
      raise exception 'AUTOTEST: confirmation périmée acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.finance_corriger_tarif(v_admin, v_projet, v_evt ->> 'id', 80, 'Avenant autotest', 'Erreur de saisie',
      public.finance_temps_concernes(v_projet, v_mois + 10) ->> 'empreinte');
    if (select jsonb_array_length(tarif_historique) from public.projets where id = v_projet) <> 3
       or (select count(*) from public.finance_periodes_actives((select tarif_historique from public.projets where id = v_projet))) <> 2
       or not exists (select 1 from public.projets p, jsonb_array_elements(p.tarif_historique) e
                       where p.id = v_projet and e = v_evt) then
      raise exception 'AUTOTEST: historique des tarifs modifié ou correction mal appliquée';
    end if;

    -- Aperçu : montants et écart d'arrondi ; TVA incompatible refusée.
    v_calc := public.finance_calculer(v_client, v_mois, array[v_projet], v_tva);
    if jsonb_array_length(v_calc -> 'blocages') <> 0 then
      raise exception 'AUTOTEST: aperçu bloqué (%)', v_calc -> 'blocages';
    end if;
    if (v_calc -> 'totaux') is distinct from '{"heures": 3.25, "total_ht": 207.50, "tva": 17.64, "total_ttc": 225.14}'::jsonb
       or (select string_agg((l ->> 'tarif') || ':' || (l ->> 'montant_ht') || ':' || (l ->> 'montant_theorique') || ':'
                             || (l ->> 'ecart_arrondi'), ' ' order by l ->> 'date_effet')
             from jsonb_array_elements(v_calc -> 'lignes') l) is distinct from '10.01:7.50:7.51:-0.01 80:200.00:200.00:0.00' then
      raise exception 'AUTOTEST: montants de l''aperçu incorrects (% / %)', v_calc -> 'totaux', v_calc -> 'lignes';
    end if;
    if not exists (select 1 from jsonb_array_elements_text(public.finance_calculer(v_client, v_mois, array[v_projet],
                     '{"regime":"taxable","territoire":"FR","taux":20,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}')
                     -> 'blocages') b where b like 'TVA incompatible%') then
      raise exception 'AUTOTEST: TVA incompatible non refusée';
    end if;

    -- Émission : aperçu périmé refusé ; puis émise ; rejouée avec la même clé → même facture.
    begin
      perform public.finance_emettre_facture(v_admin, '00000000-0000-0000-0000-0000000000a1', v_client, v_mois,
        array[v_projet], v_tva, 'empreinte-perimee', v_emetteur, v_conditions, 'facture-v1');
      raise exception 'AUTOTEST: aperçu périmé accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    v_res := public.finance_emettre_facture(v_admin, '00000000-0000-0000-0000-0000000000a2', v_client, v_mois,
      array[v_projet], v_tva, v_calc ->> 'empreinte', v_emetteur, v_conditions, 'facture-v1');
    v_res2 := public.finance_emettre_facture(v_admin, '00000000-0000-0000-0000-0000000000a2', v_client, v_mois,
      array[v_projet], v_tva, v_calc ->> 'empreinte', v_emetteur, v_conditions, 'facture-v1');
    v_facture := (v_res ->> 'facture_id')::uuid;
    if v_res ->> 'numero' not like 'ESSAI-FAC-%' or v_res2 ->> 'facture_id' <> v_res ->> 'facture_id'
       or (v_res2 ->> 'deja_emise')::boolean is not true
       or (select count(*) from public.factures where essai) <> 1 then
      raise exception 'AUTOTEST: émission ou reprise incorrecte (% / %)', v_res, v_res2;
    end if;
    if (select total_ht = 207.50 and tva = 17.64 and total_ttc = 225.14 and statut = 'emise' and pdf_statut = 'a_generer'
               and instantane_emission -> 'lignes' = v_calc -> 'lignes' and instantane_emission -> 'totaux' = v_calc -> 'totaux'
          from public.factures where id = v_facture) is not true
       or (select sum(montant_facture_ht) from public.temps where facture_id = v_facture) <> 207.50
       or (select count(*) from public.temps where facture_id = v_facture and taux_facture is not null) <> 4 then
      raise exception 'AUTOTEST: facture, instantané ou temps facturés incohérents';
    end if;
    if exists (select 1 from public.temps t, jsonb_array_elements(t.historique) e
                where t.facture_id = v_facture and e ->> 'action' = 'facturation'
                  and (e ? 'montant' or e ? 'tarif' or e ? 'taux')) then
      raise exception 'AUTOTEST: montant ou tarif visible dans l''historique du temps';
    end if;
    -- Plus rien à facturer : double facturation impossible.
    if (public.finance_calculer(v_client, v_mois, array[v_projet], v_tva) ->> 'empreinte') = v_calc ->> 'empreinte'
       or not exists (select 1 from jsonb_array_elements_text(public.finance_calculer(v_client, v_mois, array[v_projet], v_tva)
                        -> 'blocages') b where b like 'Aucun temps validé et non facturé%') then
      raise exception 'AUTOTEST: temps facturables une seconde fois';
    end if;

    -- Facture et temps figés ; aucune suppression ; aucun changement de statut direct.
    begin
      update public.factures set total_ht = 1, total_ttc = 18.64 where id = v_facture;
      raise exception 'AUTOTEST: montant d''une facture émise modifié';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.factures set statut = 'payee' where id = v_facture;
      raise exception 'AUTOTEST: statut changé directement';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      delete from public.factures where id = v_facture;
      raise exception 'AUTOTEST: facture supprimée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.temps set taux_facture = 1, montant_facture_ht = 0.25 where id = v_t[1];
      raise exception 'AUTOTEST: taux facturé modifié';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.finance_confirmer_tarif(v_admin, v_projet, 99, v_mois + 11, 'Après facturation',
        public.finance_temps_concernes(v_projet, v_mois + 11) ->> 'empreinte');
      raise exception 'AUTOTEST: tarif rétroactif accepté sur des temps facturés';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.finance_declarer_envoi(v_admin, v_facture, now(), 'email', 'x@exemple.invalid');
      raise exception 'AUTOTEST: envoi déclaré sans PDF';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Suivi : PDF (simulé dans l'autotest), envoi, règlement partiel refusé, règlement intégral, correction motivée.
    perform public.finance_contexte('pdf', '{"action":"pdf_archive","autotest":true}', v_facture);
    update public.factures set pdf_statut = 'disponible', pdf_chemin = 'autotest.pdf', pdf_empreinte = repeat('b', 64),
           pdf_taille = 1, pdf_archive_le = now() where id = v_facture;
    perform public.finance_fin_contexte();
    perform public.finance_declarer_envoi(v_admin, v_facture, now(), 'autre', null);
    begin
      perform public.finance_enregistrer_reglement(v_admin, v_facture, (now() at time zone 'America/Martinique')::date,
        'virement', null, false);
      raise exception 'AUTOTEST: paiement partiel enregistré';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.finance_enregistrer_reglement(v_admin, v_facture, (now() at time zone 'America/Martinique')::date,
      'virement', 'VIR-AUTOTEST', true);
    begin
      perform public.finance_corriger_reglement(v_admin, v_facture, 'annuler', null, null, null, '');
      raise exception 'AUTOTEST: correction sans motif acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.finance_corriger_reglement(v_admin, v_facture, 'annuler', null, null, null, 'Règlement déclaré par erreur');
    if (select statut <> 'envoyee' or date_reglement is not null or total_ttc <> 225.14
               or (select string_agg(e ->> 'action', ',' order by o) from jsonb_array_elements(historique) with ordinality x(e, o))
                  is distinct from 'emission,pdf_archive,envoi_declare,reglement_integral,reglement_annule'
          from public.factures where id = v_facture) then
      raise exception 'AUTOTEST: suivi de la facture ou historique incorrect';
    end if;

    -- Nettoyage des essais : facture, temps et compteur d'essai disparaissent.
    v_res := public.supprimer_essais_finance();
    if exists (select 1 from public.factures where essai) or exists (select 1 from public.compteurs where cle ~ '^essai_facture_')
       or exists (select 1 from public.temps where id = any(v_t)) then
      raise exception 'AUTOTEST: nettoyage des factures d''essai incomplet';
    end if;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'Finance : autotest en échec : %', sqlerrm;
    end if;
  end;
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(d::text, '|' order by d.id) from public.devis d), '')
          || coalesce((select string_agg(c.id || c.nom, '|' order by c.id) from public.collaborateurs c), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_apres;
  if v_apres is distinct from v_avant then
    raise exception 'Finance : l''autotest a modifié des données réelles';
  end if;
  if coalesce(current_setting('sgi.fin_operation', true), '') <> '' or coalesce(current_setting('sgi.rh_auteur', true), '') <> '' then
    raise exception 'Finance : contexte resté actif après l''autotest';
  end if;
end
$$;
