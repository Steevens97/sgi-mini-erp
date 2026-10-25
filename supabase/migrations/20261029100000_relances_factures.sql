-- Relances automatiques des factures (1re version). Décisions de l'utilisateur du 25/10/2026 (voir CLAUDE.md) :
--   - factures seulement : émises ou envoyées, impayées, échues ; aucun rappel de congés ni de notes de frais ;
--   - relances n° 1, 2, 3 à J+7, J+15, J+30 après l'échéance, dans l'ordre, au moins 8 jours entre deux relances
--     ACCEPTÉES par le fournisseur, au plus une relance par facture et par jour (date en Martinique : réservation,
--     tentative ou acceptation ce jour-là) ; du lundi au vendredi, de 8 h à 17 h en Martinique (jours fériés non exclus) ;
--   - la demande au fournisseur (Resend) est FIGÉE à la réservation (expéditeur, réponse, destinataire, objet, texte,
--     nom, type et empreinte de la pièce jointe, étiquettes) ; une reprise renvoie exactement la même demande avec la
--     même clé anti-doublon, jusqu'à la limite de reprise (première tentative + 20 h, jamais renouvelée) ;
--   - réservation, tentative, acceptation et livraison sont distinctes : date_envoi n'est renseignée qu'à l'acceptation
--     par le fournisseur ou par un constat admin tracé ;
--   - une relance incertaine (réservée, en cours, à vérifier), refusée ou rejetée bloque toute nouvelle relance de la
--     facture, jusqu'à la résolution par l'administrateur (motif obligatoire, tracée) ;
--   - événements de livraison (webhook signé) : REÇUS DURABLEMENT dans la 14e table relances_evenements (accord de
--     l'utilisateur du 25/10/2026), puis rapprochés de leur relance, même longtemps après (incident prolongé) ; en double,
--     en retard ou dans le désordre, ils ne font jamais régresser un état et n'effacent jamais un rejet définitif ; jamais
--     appliqués si l'étiquette et l'identifiant désignent deux relances différentes ou si le compte fournisseur diffère
--     (alerte, en attente) ; un rapprochement ne déclenche JAMAIS d'envoi ;
--   - compte fournisseur : RÉFÉRENCE NON SECRÈTE configurée (ex. « resend-sgi »), recopiée sur la relance à la première
--     tentative et sur chaque événement reçu ; une reprise ou un rapprochement avec une autre référence est refusé ;
--   - aucun secret dans la demande, l'historique ou les messages d'erreur ; aucun appel réseau pendant la migration ;
--     la fonction de déclenchement (pour la future tâche Cron) échoue explicitement si Vault ou pg_net manque.
-- Cette migration NE CRÉE AUCUNE TÂCHE CRON et n'installe aucune extension (activation : migration distincte, sur accord).
-- Compatible avec le site en ligne : il ne lit ni n'écrit la table relances (vérifié) ; aucune autre table existante n'est
-- modifiée ; une table est AJOUTÉE (relances_evenements).

-- 0. Préalables -----------------------------------------------------------------------------------------------
do $$
declare
  v_nb integer;
  v_liste text;
begin
  select count(*) into v_nb from supabase_migrations.schema_migrations
   where version in ('20261027100000', '20261028100000');
  if v_nb <> 2 then
    raise exception 'Relances : les migrations Finance (20261027100000) et Absences (20261028100000) doivent être appliquées avant';
  end if;
  if to_regclass('public.relances_evenements') is not null then
    raise exception 'Relances : la table relances_evenements existe déjà ; examen nécessaire';
  end if;
  select count(*) into v_nb from public.relances;
  if v_nb > 0 then
    raise exception 'Relances : % relance(s) existent déjà ; examen nécessaire avant de poser les règles', v_nb;
  end if;
  select string_agg(column_name, ',' order by ordinal_position) into v_liste
    from information_schema.columns where table_schema = 'public' and table_name = 'relances';
  if v_liste is distinct from 'id,facture_id,date_envoi,canal,message,created_at' then
    raise exception 'Relances : colonnes inattendues (%) ; examen nécessaire', v_liste;
  end if;
  -- Fonction remplacée par ce module : elle doit être EXACTEMENT celle de la migration Finance appliquée.
  if (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'supprimer_essais_finance') is distinct from 'bd3538340aaedcb37811c2b975708957' then
    raise exception 'Relances : supprimer_essais_finance absente ou différente de la version examinée ; nouvel examen nécessaire';
  end if;
end
$$;

-- 1. Colonnes (approuvées par l'utilisateur le 25/10/2026) ---------------------------------------------------------
-- date_envoi : facultative, sans valeur par défaut (une réservation ne prouve aucun envoi).
alter table public.relances alter column date_envoi drop default;
alter table public.relances alter column date_envoi drop not null;
alter table public.relances
  add column if not exists jour_relance date,                -- date de la réservation, en Martinique
  add column if not exists rang smallint,                    -- relance n° 1, 2 ou 3
  add column if not exists essai boolean not null default false,
  add column if not exists destinataire text,                -- recopiés de la demande figée (lisibles à l'écran)
  add column if not exists objet text,
  add column if not exists requete_fournisseur jsonb,        -- demande complète au fournisseur, figée, SANS secret
  add column if not exists requete_empreinte text,           -- SHA-256 de requete_fournisseur::text
  add column if not exists pdf_empreinte text,               -- SHA-256 du PDF archivé joint
  add column if not exists cle_idempotence text,             -- clé anti-doublon transmise au fournisseur
  add column if not exists statut text,
  add column if not exists tentatives smallint not null default 0,
  add column if not exists premiere_tentative_le timestamptz,
  add column if not exists derniere_tentative_le timestamptz,
  add column if not exists limite_reprise timestamptz,       -- première tentative + 20 h, jamais renouvelée
  add column if not exists compte_fournisseur text,          -- RÉFÉRENCE NON SECRÈTE du compte (configurée), 1re tentative
  add column if not exists accepte_le timestamptz,           -- acceptation par le fournisseur (réponse ou événement)
  add column if not exists fournisseur_id text,              -- identifiant de l'email chez le fournisseur
  add column if not exists livre_le timestamptz,             -- remis au serveur du destinataire (webhook vérifié)
  add column if not exists rebond_le timestamptz,            -- rejet définitif (webhook vérifié)
  add column if not exists rebond_motif text,
  add column if not exists erreur text,
  add column if not exists resolu_par uuid,                  -- compte (sans lien : un compte révoqué est supprimé)
  add column if not exists resolu_par_nom text,
  add column if not exists resolu_le timestamptz,
  add column if not exists motif_resolution text,
  add column if not exists historique jsonb not null default '[]'::jsonb;
-- La table est vide (vérifié ci-dessus) : les colonnes indispensables deviennent obligatoires.
alter table public.relances alter column jour_relance set not null;
alter table public.relances alter column rang set not null;
alter table public.relances alter column destinataire set not null;
alter table public.relances alter column objet set not null;
alter table public.relances alter column message set not null;
alter table public.relances alter column requete_fournisseur set not null;
alter table public.relances alter column requete_empreinte set not null;
alter table public.relances alter column pdf_empreinte set not null;
alter table public.relances alter column cle_idempotence set not null;
alter table public.relances alter column statut set not null;

-- 2. Contraintes ---------------------------------------------------------------------------------------------------
do $$
declare
  v_c record;
begin
  for v_c in select conname from pg_constraint
              where conrelid = 'public.relances'::regclass and conname like 'relances\_%' and contype = 'c' loop
    execute format('alter table public.relances drop constraint %I', v_c.conname);
  end loop;
end
$$;
alter table public.relances add constraint relances_canal_email check (canal = 'email');
alter table public.relances add constraint relances_statut_liste
  check (statut in ('reservee', 'en_cours', 'acceptee', 'refusee', 'rejetee', 'a_verifier', 'abandonnee'));
alter table public.relances add constraint relances_rang_liste check (rang between 1 and 3);
alter table public.relances add constraint relances_tentatives_bornees check (tentatives between 0 and 5);
alter table public.relances add constraint relances_date_envoi_acceptation
  check ((statut in ('acceptee', 'rejetee')) = (date_envoi is not null));
alter table public.relances add constraint relances_tentative_complete
  check (statut <> 'en_cours' or (tentatives >= 1 and premiere_tentative_le is not null and limite_reprise is not null
                                  and derniere_tentative_le is not null and compte_fournisseur is not null));
alter table public.relances add constraint relances_rejet_date check (statut <> 'rejetee' or rebond_le is not null);
alter table public.relances add constraint relances_historique_liste check (jsonb_typeof(historique) = 'array');
alter table public.relances add constraint relances_empreintes_format
  check (requete_empreinte ~ '^[0-9a-f]{64}$' and pdf_empreinte ~ '^[0-9a-f]{64}$'
         and (compte_fournisseur is null or compte_fournisseur ~ '^[A-Za-z0-9._-]{3,64}$'));
alter table public.relances add constraint relances_resolution_complete
  check ((resolu_le is null) = (resolu_par is null) and (resolu_le is null or length(btrim(coalesce(motif_resolution, ''))) >= 5));
drop index if exists public.relances_cle_unique;
create unique index relances_cle_unique on public.relances (cle_idempotence);
drop index if exists public.relances_fournisseur_unique;
create unique index relances_fournisseur_unique on public.relances (fournisseur_id) where fournisseur_id is not null;
-- Au plus une réservation par facture et par jour (Martinique).
drop index if exists public.relances_une_par_jour;
create unique index relances_une_par_jour on public.relances (facture_id, jour_relance);
-- Chaque relance n° 1, 2, 3 au plus une fois (une relance abandonnée ou refusée, certaine de n'être jamais partie, se refait).
drop index if exists public.relances_rang_unique;
create unique index relances_rang_unique on public.relances (facture_id, rang) where statut not in ('abandonnee', 'refusee');
-- Au plus UNE relance non résolue par facture : elle bloque toute nouvelle relance automatique, même les jours suivants.
drop index if exists public.relances_une_non_resolue;
create unique index relances_une_non_resolue on public.relances (facture_id)
  where (statut in ('reservee', 'en_cours', 'a_verifier', 'refusee') and resolu_le is null)
     or (statut = 'rejetee' and (resolu_le is null or resolu_le < rebond_le));

-- 2b. Événements de livraison reçus (14e table, approuvée le 25/10/2026) : réception DURABLE des événements signés, en
--     attente de rapprochement aussi longtemps que nécessaire. Seules les données utiles sont gardées : ni corps complet,
--     ni destinataire, ni objet, ni signature, ni secret. Doublons : clé primaire = identifiant de l'événement chez le
--     fournisseur (svix-id). Conservation : en attente jusqu'au rapprochement ou au classement « sans suite » par
--     l'administrateur (jamais supprimé automatiquement) ; rapproché ou sans suite : supprimé 30 jours après.
create table public.relances_evenements (
  evenement_id text primary key,                 -- identifiant de l'événement chez le fournisseur (anti-doublon)
  type text not null,                            -- email.sent, email.delivered, email.bounced…
  fournisseur_id text,                           -- identifiant de l'email chez le fournisseur
  relance_id uuid,                               -- étiquette de relance portée par l'événement (sans lien obligatoire)
  compte_fournisseur text not null,              -- référence NON SECRÈTE du compte qui a signé l'événement
  survenu_le timestamptz not null,               -- date de l'événement chez le fournisseur
  detail text,                                   -- motif d'un rejet seulement (masqué s'il ressemble à un secret)
  recu_le timestamptz not null default now(),    -- réception par le site
  statut text not null default 'en_attente',
  alerte text,                                   -- raison explicite d'un non-rapprochement (conflit, autre compte…)
  rapproche_le timestamptz,
  relance_rapprochee uuid,
  classe_par uuid,                               -- classement « sans suite » par l'administrateur (motif obligatoire)
  classe_par_nom text,
  classe_le timestamptz,
  motif_classement text,
  constraint relances_evenements_identifiant check (length(evenement_id) between 1 and 100),
  constraint relances_evenements_type check (type ~ '^email\.[a-z_]{1,34}$'),
  constraint relances_evenements_fournisseur check (fournisseur_id is null or length(fournisseur_id) between 1 and 100),
  constraint relances_evenements_cible check (fournisseur_id is not null or relance_id is not null),
  constraint relances_evenements_compte check (compte_fournisseur ~ '^[A-Za-z0-9._-]{3,64}$'),
  constraint relances_evenements_detail check (detail is null or length(detail) <= 300),
  constraint relances_evenements_alerte check (alerte is null or length(alerte) <= 300),
  constraint relances_evenements_statut check (statut in ('en_attente', 'rapproche', 'sans_suite')),
  constraint relances_evenements_rapprochement
    check ((statut = 'rapproche') = (rapproche_le is not null and relance_rapprochee is not null)),
  constraint relances_evenements_classement
    check ((statut = 'sans_suite') = (classe_le is not null) and (classe_le is null) = (classe_par is null)
           and (classe_le is null or length(btrim(coalesce(motif_classement, ''))) >= 5)));
create index relances_evenements_attente_fournisseur on public.relances_evenements (fournisseur_id) where statut = 'en_attente';
create index relances_evenements_attente_relance on public.relances_evenements (relance_id) where statut = 'en_attente';

-- 3. Outils internes -----------------------------------------------------------------------------------------------
-- Paramètres approuvés (toute modification = nouvelle migration, sur accord de l'utilisateur).
create or replace function public.relances_parametres()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'seuils_jours', jsonb_build_array(7, 15, 30),  -- relance n° 1, 2, 3 : jours écoulés depuis l'échéance
    'ecart_min_jours', 8,                         -- entre deux relances ACCEPTÉES
    'jours_isodow', jsonb_build_array(1, 2, 3, 4, 5),
    'heure_debut', 8, 'heure_fin', 17,            -- 8 h 00 inclus, 17 h 00 exclu, heure de Martinique
    'reprise_minutes', 10,                        -- délai minimal entre deux tentatives d'une même demande
    'tentatives_max', 5,
    'limite_reprise_heures', 20,                  -- marge de 4 h avant les 24 h de conservation des clés (Resend)
    'reservation_sans_tentative_heures', 20,
    'fuseau', 'America/Martinique');
$$;

-- Seule source de l'heure pour les règles (l'autotest et les essais locaux la fixent le temps d'une vérification ;
-- la définition d'origine est contrôlée par empreinte à la fin de cette migration).
create or replace function public.relances_maintenant()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

create or replace function public.relances_jour(p_instant timestamptz)
returns date
language sql
immutable
as $$
  select (p_instant at time zone 'America/Martinique')::date;
$$;

create or replace function public.relances_horaire_ouvre(p_instant timestamptz)
returns boolean
language sql
immutable
as $$
  select extract(isodow from p_instant at time zone 'America/Martinique')::int between 1 and 5
     and extract(hour from p_instant at time zone 'America/Martinique')::int >= 8
     and extract(hour from p_instant at time zone 'America/Martinique')::int < 17;
$$;

-- Adresse d'essai ou réservée (RFC 2606, RFC 6761) et adresses de simulation du fournisseur : jamais destinataires
-- (décision de l'utilisateur : aucune adresse fictive pour des essais réels ; les adresses de simulation de Resend
-- restent refusées tant que l'utilisateur ne les a pas autorisées).
create or replace function public.relances_adresse_fictive(p_adresse text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(split_part(p_adresse, '@', 2)), '') ~
         '(^|\.)(exemple\.invalid|example\.(com|net|org)|resend\.dev)$|\.(invalid|test|example|localhost)$|^localhost$|^$';
$$;

create or replace function public.relances_adresse_valide(p_adresse text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_adresse, '') ~ '^[^@\s<>,;"]+@[^@\s<>,;"]+\.[^@\s<>,;"]+$' and length(p_adresse) <= 254;
$$;

-- Aucun secret d'authentification ne doit être enregistré (demande, historique, erreurs, motifs).
create or replace function public.relances_contient_secret(p_texte text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_texte, '') ~* '(re_[a-z0-9_]{8,}|whsec_|bearer[[:space:]]|authorization|api[_-]?key|x-api|secret|password|mot de passe|svix-signature)';
$$;

create or replace function public.relances_contexte(p_operation text)
returns void
language sql
as $$
  select set_config('sgi.rel_operation', coalesce(p_operation, ''), true);
$$;

create or replace function public.relances_fin_contexte()
returns void
language sql
as $$
  select set_config('sgi.rel_operation', '', true);
$$;

create or replace function public.relances_evenement(p_action text, p_details jsonb)
returns jsonb
language sql
stable
as $$
  select jsonb_build_array(jsonb_build_object('action', p_action, 'le', public.relances_maintenant())
                           || coalesce(p_details, '{}'::jsonb));
$$;

-- Situation d'une facture vis-à-vis des relances : la relance due aujourd'hui (rang) ou la raison de l'attente.
-- UNE seule fonction pour l'aperçu, la simulation, la réservation et le déclencheur : mêmes règles partout.
create or replace function public.relances_situation(p_facture uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.factures;
  v_param jsonb := public.relances_parametres();
  v_maintenant timestamptz := public.relances_maintenant();
  v_jour date := public.relances_jour(public.relances_maintenant());
  v_email text;
  v_bloquante public.relances;
  v_parties integer;
  v_rang integer;
  v_seuil integer;
  v_derniere date;
  v_retard integer;
  v_base jsonb;
begin
  select * into f from public.factures where id = p_facture;
  if not found then
    return jsonb_build_object('rang', null, 'blocage', 'Facture introuvable.');
  end if;
  select nullif(btrim(c.email_contact), '') into v_email from public.clients c where c.id = f.client_id;
  v_retard := case when f.date_echeance is null then null else v_jour - f.date_echeance end;
  select count(*) into v_parties from public.relances where facture_id = p_facture and statut in ('acceptee', 'rejetee');
  v_base := jsonb_build_object('retard_jours', v_retard, 'relances_parties', v_parties,
                               'pdf_disponible', f.pdf_statut = 'disponible' and f.pdf_empreinte is not null,
                               'email_client', v_email is not null);
  if f.statut not in ('emise', 'envoyee') then
    return v_base || jsonb_build_object('rang', null, 'blocage', 'Facture non émise ou réglée : aucune relance.');
  end if;
  if f.date_echeance is null or f.date_echeance >= v_jour then
    return v_base || jsonb_build_object('rang', null, 'blocage', 'Facture non échue.');
  end if;
  if f.pdf_statut is distinct from 'disponible' or f.pdf_empreinte is null then
    return v_base || jsonb_build_object('rang', null, 'blocage', 'PDF archivé indisponible : aucune relance (à traiter à part).');
  end if;
  if v_email is null then
    return v_base || jsonb_build_object('rang', null, 'blocage', 'Client sans email : aucune relance (à traiter à part).');
  end if;
  select * into v_bloquante from public.relances r
   where r.facture_id = p_facture
     and ((r.statut in ('reservee', 'en_cours', 'a_verifier', 'refusee') and r.resolu_le is null)
          or (r.statut = 'rejetee' and (r.resolu_le is null or r.resolu_le < r.rebond_le)))
   limit 1;
  if found then
    return v_base || jsonb_build_object('rang', null, 'relance_bloquante', v_bloquante.id,
      'blocage', format('Relance n° %s %s : aucune nouvelle relance avant sa résolution.', v_bloquante.rang,
        case v_bloquante.statut when 'reservee' then 'réservée (aucun envoi confirmé)'
                                when 'en_cours' then 'en cours (envoi non confirmé)'
                                when 'a_verifier' then 'à vérifier (envoi incertain)'
                                when 'refusee' then 'refusée par le fournisseur'
                                else 'rejetée par le serveur du destinataire' end));
  end if;
  if v_parties >= jsonb_array_length(v_param -> 'seuils_jours') then
    return v_base || jsonb_build_object('rang', null, 'blocage', 'Relances terminées : suivi manuel.');
  end if;
  v_rang := v_parties + 1;
  v_seuil := (v_param -> 'seuils_jours' ->> (v_rang - 1))::integer;
  if v_retard < v_seuil then
    return v_base || jsonb_build_object('rang', null, 'rang_suivant', v_rang,
      'blocage', format('Relance n° %s prévue à J+%s (le %s).', v_rang, v_seuil, to_char(f.date_echeance + v_seuil, 'DD/MM/YYYY')));
  end if;
  select max(public.relances_jour(date_envoi)) into v_derniere from public.relances
   where facture_id = p_facture and date_envoi is not null;
  if v_derniere is not null and v_jour - v_derniere < (v_param ->> 'ecart_min_jours')::integer then
    return v_base || jsonb_build_object('rang', null, 'rang_suivant', v_rang,
      'blocage', format('Écart minimal de %s jours depuis la dernière relance acceptée : relance n° %s possible le %s.',
        v_param ->> 'ecart_min_jours', v_rang, to_char(v_derniere + (v_param ->> 'ecart_min_jours')::integer, 'DD/MM/YYYY')));
  end if;
  if exists (select 1 from public.relances r where r.facture_id = p_facture
               and (r.jour_relance = v_jour or public.relances_jour(r.derniere_tentative_le) = v_jour
                    or public.relances_jour(r.date_envoi) = v_jour)) then
    return v_base || jsonb_build_object('rang', null, 'rang_suivant', v_rang,
      'blocage', 'Une relance a déjà été réservée, tentée ou acceptée aujourd''hui pour cette facture.');
  end if;
  if not public.relances_horaire_ouvre(v_maintenant) then
    return v_base || jsonb_build_object('rang', null, 'rang_suivant', v_rang,
      'blocage', 'Hors des horaires d''envoi (du lundi au vendredi, de 8 h à 17 h, heure de Martinique).');
  end if;
  return v_base || jsonb_build_object('rang', v_rang, 'blocage', null);
end
$$;

-- Contrôle de la demande figée : forme exacte, cohérence avec la facture, aucune adresse fictive, aucun secret.
create or replace function public.relances_controle_requete(p_requete jsonb, p_relance uuid, p_facture uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.factures;
  v_email text;
  v_from text;
  v_adresse_from text;
  v_to text;
  v_cles text;
begin
  select * into f from public.factures where id = p_facture;
  select lower(nullif(btrim(email_contact), '')) into v_email from public.clients where id = f.client_id;
  if p_requete is null or jsonb_typeof(p_requete) <> 'object' then
    return 'demande absente';
  end if;
  select string_agg(k, ',' order by k) into v_cles from jsonb_object_keys(p_requete) k;
  if v_cles is distinct from 'fournisseur,from,piece_jointe,reply_to,subject,tags,text,to,version' then
    return 'champs de la demande inattendus (' || coalesce(v_cles, 'aucun') || ')';
  end if;
  if public.relances_contient_secret(p_requete::text) then
    return 'la demande contient un élément ressemblant à un secret d''authentification';
  end if;
  if p_requete ->> 'fournisseur' is distinct from 'resend' or p_requete ->> 'version' is distinct from '1' then
    return 'fournisseur ou version de demande non prévus';
  end if;
  if jsonb_typeof(p_requete -> 'from') <> 'string' or jsonb_typeof(p_requete -> 'to') <> 'string'
     or jsonb_typeof(p_requete -> 'subject') <> 'string' or jsonb_typeof(p_requete -> 'text') <> 'string'
     or jsonb_typeof(p_requete -> 'reply_to') not in ('string', 'null') then
    return 'champs texte mal formés';
  end if;
  v_from := p_requete ->> 'from';
  v_to := p_requete ->> 'to';
  if (v_from || v_to || (p_requete ->> 'subject') || coalesce(p_requete ->> 'reply_to', '')) ~ '[\r\n]' then
    return 'retour à la ligne interdit dans les en-têtes';
  end if;
  v_adresse_from := lower(coalesce(substring(v_from from '<([^<>]+)>\s*$'), v_from));
  if not public.relances_adresse_valide(v_adresse_from) then
    return 'adresse d''expéditeur invalide';
  end if;
  if p_requete ->> 'reply_to' is not null and not public.relances_adresse_valide(p_requete ->> 'reply_to') then
    return 'adresse de réponse invalide';
  end if;
  if not public.relances_adresse_valide(v_to) or v_to <> lower(btrim(v_to)) then
    return 'adresse du destinataire invalide';
  end if;
  if public.relances_adresse_fictive(v_to) then
    return 'destinataire fictif ou réservé aux essais : refusé';
  end if;
  if f.essai then
    if left(p_requete ->> 'subject', 8) <> '[ESSAI] ' then
      return 'relance d''essai : l''objet doit commencer par « [ESSAI] »';
    end if;
  else
    if v_to is distinct from v_email then
      return 'relance réelle : le destinataire doit être l''email du client';
    end if;
    if split_part(v_adresse_from, '@', 2) = 'resend.dev' then
      return 'relance réelle : expéditeur de test du fournisseur interdit (domaine vérifié nécessaire)';
    end if;
    if (p_requete ->> 'subject') ilike '%[ESSAI]%' or (p_requete ->> 'text') ilike '%[ESSAI]%' then
      return 'relance réelle : mention d''essai interdite';
    end if;
  end if;
  if length(p_requete ->> 'subject') not between 5 and 200 or length(p_requete ->> 'text') not between 20 and 5000 then
    return 'objet ou texte de longueur anormale';
  end if;
  if position(f.numero in (p_requete ->> 'subject')) = 0 or position(f.numero in (p_requete ->> 'text')) = 0 then
    return 'le numéro de la facture doit figurer dans l''objet et le texte';
  end if;
  if p_requete -> 'piece_jointe' is distinct from jsonb_build_object('nom', f.numero || '.pdf', 'type', 'application/pdf',
                                                                    'empreinte', f.pdf_empreinte) then
    return 'pièce jointe différente du PDF archivé de la facture';
  end if;
  if p_requete -> 'tags' is distinct from jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', p_relance::text)) then
    return 'étiquette de la relance inattendue';
  end if;
  return null;
end
$$;

-- 4. Déclencheur : toutes les règles, quel que soit le chemin d'écriture (tableau de bord compris) ------------------
create or replace function public.relances_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := coalesce(current_setting('sgi.rel_operation', true), '');
  v_maintenant timestamptz := public.relances_maintenant();
  v_situation jsonb;
  v_erreur text;
  v_ancien integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Relances : écriture directe interdite.';
  end if;
  if tg_op = 'DELETE' then
    if old.essai and coalesce(current_setting('sgi.fin_operation', true), '') = 'nettoyage_essais' then
      return old;
    end if;
    raise exception 'Suppression refusée : une relance ne se supprime jamais (seules les relances d''essai, au nettoyage).';
  end if;

  if tg_op = 'INSERT' then
    if v_op <> 'reserver' then
      raise exception 'Une relance naît uniquement de la réservation par l''application.';
    end if;
    perform 1 from public.factures where id = new.facture_id for update;
    v_situation := public.relances_situation(new.facture_id);
    if v_situation ->> 'blocage' is not null then
      raise exception 'Relance refusée : %', v_situation ->> 'blocage';
    end if;
    if new.rang is distinct from (v_situation ->> 'rang')::smallint then
      raise exception 'Relance refusée : la relance due est la n° % (demandée : n° %).', v_situation ->> 'rang', new.rang;
    end if;
    v_erreur := public.relances_controle_requete(new.requete_fournisseur, new.id, new.facture_id);
    if v_erreur is not null then
      raise exception 'Relance refusée : %.', v_erreur;
    end if;
    if new.compte_fournisseur is not null or new.tentatives <> 0 or new.premiere_tentative_le is not null
       or new.derniere_tentative_le is not null or new.limite_reprise is not null or new.accepte_le is not null
       or new.fournisseur_id is not null or new.date_envoi is not null or new.livre_le is not null or new.rebond_le is not null
       or new.resolu_le is not null or new.erreur is not null or new.historique is distinct from '[]'::jsonb then
      raise exception 'Relance refusée : une réservation ne porte ni tentative, ni acceptation, ni historique.';
    end if;
    new.jour_relance := public.relances_jour(v_maintenant);
    new.essai := (select essai from public.factures where id = new.facture_id);
    new.canal := 'email';
    new.statut := 'reservee';
    new.destinataire := new.requete_fournisseur ->> 'to';
    new.objet := new.requete_fournisseur ->> 'subject';
    new.message := new.requete_fournisseur ->> 'text';
    new.pdf_empreinte := new.requete_fournisseur -> 'piece_jointe' ->> 'empreinte';
    new.requete_empreinte := encode(sha256(convert_to(new.requete_fournisseur::text, 'UTF8')), 'hex');
    new.cle_idempotence := 'sgi-relance-' || new.id::text;
    new.created_at := v_maintenant;
    new.historique := public.relances_evenement('reservation', jsonb_build_object('rang', new.rang));
    return new;
  end if;

  -- UPDATE
  if v_op not in ('prendre', 'resultat', 'evenement', 'resolution') then
    raise exception 'Relance : modification réservée à l''application.';
  end if;
  if (new.id, new.facture_id, new.rang, new.jour_relance, new.essai, new.destinataire, new.objet, new.message, new.canal,
      new.requete_fournisseur, new.requete_empreinte, new.pdf_empreinte, new.cle_idempotence, new.created_at)
     is distinct from
     (old.id, old.facture_id, old.rang, old.jour_relance, old.essai, old.destinataire, old.objet, old.message, old.canal,
      old.requete_fournisseur, old.requete_empreinte, old.pdf_empreinte, old.cle_idempotence, old.created_at) then
    raise exception 'Relance : la demande figée ne se modifie jamais (une reprise renvoie exactement la même demande).';
  end if;
  -- Valeurs posées une seule fois : jamais remplacées ni effacées.
  if (old.premiere_tentative_le is not null and new.premiere_tentative_le is distinct from old.premiere_tentative_le)
     or (old.limite_reprise is not null and new.limite_reprise is distinct from old.limite_reprise)
     or (old.compte_fournisseur is not null and new.compte_fournisseur is distinct from old.compte_fournisseur)
     or (old.fournisseur_id is not null and new.fournisseur_id is distinct from old.fournisseur_id)
     or (old.accepte_le is not null and new.accepte_le is distinct from old.accepte_le)
     or (old.date_envoi is not null and new.date_envoi is distinct from old.date_envoi)
     or (old.livre_le is not null and new.livre_le is distinct from old.livre_le)
     or (old.rebond_le is not null and new.rebond_le is distinct from old.rebond_le)
     or (old.rebond_motif is not null and new.rebond_motif is distinct from old.rebond_motif) then
    raise exception 'Relance : une valeur déjà constatée (tentative, limite, compte, acceptation, livraison, rejet) ne change jamais.';
  end if;
  if new.limite_reprise is distinct from old.limite_reprise
     and new.limite_reprise is distinct from new.premiere_tentative_le
                                             + make_interval(hours => (public.relances_parametres() ->> 'limite_reprise_heures')::int) then
    raise exception 'Relance : limite de reprise calculée depuis la première tentative seulement.';
  end if;
  if (new.tentatives, new.derniere_tentative_le, new.premiere_tentative_le, new.compte_fournisseur, new.limite_reprise)
     is distinct from (old.tentatives, old.derniere_tentative_le, old.premiere_tentative_le, old.compte_fournisseur, old.limite_reprise)
     and (v_op <> 'prendre' or new.tentatives <> old.tentatives + 1) then
    raise exception 'Relance : une tentative ne s''enregistre que par la prise de la demande, une à la fois.';
  end if;
  if (new.resolu_par, new.resolu_par_nom, new.resolu_le, new.motif_resolution)
     is distinct from (old.resolu_par, old.resolu_par_nom, old.resolu_le, old.motif_resolution)
     and (v_op <> 'resolution' or new.resolu_le is null) then
    raise exception 'Relance : la résolution est réservée à l''administrateur (motif obligatoire).';
  end if;
  -- Historique : ajout seul.
  v_ancien := jsonb_array_length(old.historique);
  if jsonb_array_length(new.historique) <= v_ancien
     or (v_ancien > 0 and (select jsonb_agg(e order by i) from jsonb_array_elements(new.historique) with ordinality x(e, i)
                            where i <= v_ancien) is distinct from old.historique) then
    raise exception 'Relance : historique en ajout seul, par la base.';
  end if;
  if public.relances_contient_secret(new.historique::text) or public.relances_contient_secret(new.erreur)
     or public.relances_contient_secret(new.rebond_motif) or public.relances_contient_secret(new.motif_resolution) then
    raise exception 'Relance : un secret d''authentification ne doit jamais être enregistré.';
  end if;
  -- Transitions permises (jamais de régression ; un rejet définitif n'est jamais effacé).
  if not (
       (v_op = 'prendre' and ((old.statut = 'reservee' and new.statut in ('en_cours', 'abandonnee'))
                              or (old.statut = 'en_cours' and new.statut in ('en_cours', 'a_verifier'))))
    or (v_op = 'resultat' and ((old.statut = 'en_cours' and new.statut in ('en_cours', 'acceptee', 'refusee', 'a_verifier'))
                               or (old.statut in ('a_verifier', 'abandonnee') and new.statut in (old.statut, 'acceptee'))
                               or (old.statut in ('acceptee', 'rejetee', 'refusee') and new.statut = old.statut)))
    or (v_op = 'evenement' and (new.statut = old.statut
                                or (old.statut in ('en_cours', 'a_verifier', 'abandonnee') and new.statut in ('acceptee', 'rejetee'))
                                or (old.statut = 'acceptee' and new.statut = 'rejetee')))
    or (v_op = 'resolution' and ((old.statut in ('reservee', 'en_cours', 'a_verifier') and new.statut = 'abandonnee')
                                 or (old.statut in ('en_cours', 'a_verifier') and new.statut = 'acceptee')
                                 or (old.statut in ('refusee', 'rejetee') and new.statut = old.statut)))) then
    raise exception 'Relance : changement d''état interdit (% → %, %).', old.statut, new.statut, v_op;
  end if;
  if v_op = 'prendre' and new.statut = 'abandonnee' and old.tentatives <> 0 then
    raise exception 'Relance : une demande déjà tentée ne s''abandonne que par une résolution de l''administrateur.';
  end if;
  return new;
end
$$;
drop trigger if exists relances_controle on public.relances;
create trigger relances_controle before insert or update or delete on public.relances
  for each row execute function public.relances_controle();

-- 5. Fonctions de service (clé secrète seulement, appelées par la route serveur ou l'écran après exigerAdmin) ------
-- 5a. Aperçu (aucune écriture) : factures émises ou envoyées, impayées et échues, avec la relance due ou la raison de
--     l'attente ; factures sans PDF archivé et clients sans email signalés séparément. Sert aussi à la simulation.
create or replace function public.relances_apercu()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'facture_id', f.id, 'numero', f.numero, 'essai', f.essai, 'statut', f.statut,
           'date_emission', f.date_emission, 'date_echeance', f.date_echeance, 'total_ttc', f.total_ttc,
           'client_nom', c.nom, 'client_email', nullif(btrim(c.email_contact), ''),
           'pdf_empreinte', f.pdf_empreinte, 'pdf_chemin', f.pdf_chemin)
           || public.relances_situation(f.id) order by f.date_echeance, f.numero), '[]'::jsonb)
    from public.factures f join public.clients c on c.id = f.client_id
   where f.statut in ('emise', 'envoyee') and f.date_echeance < public.relances_jour(public.relances_maintenant());
$$;

-- 5b. Réservation (avant tout appel au fournisseur, transaction validée AVANT l'appel). Rejouée avec le même
--     identifiant (réponse perdue) : renvoie la même réservation. Deux réservations simultanées : la seconde échoue
--     sur le verrou de la facture puis sur les règles (une seule relance non résolue, une par jour).
create or replace function public.relances_reserver(p_relance uuid, p_facture uuid, p_rang integer, p_requete jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v public.relances;
  v_situation jsonb;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  perform 1 from public.factures where id = p_facture for update;
  select * into v from public.relances where id = p_relance;
  if found then
    if v.facture_id <> p_facture or v.rang <> p_rang or v.requete_fournisseur is distinct from p_requete then
      raise exception 'Relance : cet identifiant désigne déjà une autre demande.';
    end if;
    return jsonb_build_object('reservee', true, 'deja', true, 'relance_id', v.id, 'statut', v.statut);
  end if;
  v_situation := public.relances_situation(p_facture);
  if v_situation ->> 'blocage' is not null then
    return jsonb_build_object('reservee', false, 'motif', v_situation ->> 'blocage');
  end if;
  perform public.relances_contexte('reserver');
  insert into public.relances (id, facture_id, rang, requete_fournisseur, jour_relance, destinataire, objet, message,
                               requete_empreinte, pdf_empreinte, cle_idempotence, statut)
  values (p_relance, p_facture, p_rang, p_requete, current_date, '-', '-', '-', repeat('0', 64), repeat('0', 64), '-', 'reservee')
  returning * into v;
  perform public.relances_fin_contexte();
  return jsonb_build_object('reservee', true, 'deja', false, 'relance_id', v.id, 'statut', v.statut,
                            'cle_idempotence', v.cle_idempotence);
end
$$;

-- 5c. Prise d'une demande pour UNE tentative (réservée, ou en cours après au moins 10 minutes). Verrous : facture
--     puis relance. La tentative est enregistrée (et validée) AVANT l'appel au fournisseur. Ne renvoie jamais de
--     demande à envoyer si : facture réglée entre-temps, compte fournisseur différent de celui de la 1re tentative,
--     limite de reprise atteinte (jamais renouvelée), trop de tentatives, ou hors des horaires.
create or replace function public.relances_prendre(p_relance uuid, p_compte text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v public.relances;
  f public.factures;
  v_param jsonb := public.relances_parametres();
  v_maintenant timestamptz := public.relances_maintenant();
  v_statut text;
  v_motif text;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  if coalesce(p_compte, '') !~ '^[A-Za-z0-9._-]{3,64}$' or public.relances_contient_secret(p_compte) then
    raise exception 'Relance : référence du compte fournisseur absente ou mal formée (référence non secrète attendue).';
  end if;
  select * into f from public.factures where id = (select facture_id from public.relances where id = p_relance) for update;
  select * into v from public.relances where id = p_relance for update;
  if not found then
    raise exception 'Relance introuvable.';
  end if;
  if v.statut not in ('reservee', 'en_cours') then
    return jsonb_build_object('action', 'rien', 'statut', v.statut);
  end if;
  if v.statut = 'en_cours'
     and v.derniere_tentative_le > v_maintenant - make_interval(mins => (v_param ->> 'reprise_minutes')::int) then
    return jsonb_build_object('action', 'attendre', 'statut', v.statut, 'motif', 'Tentative récente : reprise après 10 minutes.');
  end if;
  -- Décisions sans appel au fournisseur.
  if f.statut not in ('emise', 'envoyee') then
    v_statut := case when v.tentatives = 0 then 'abandonnee' else 'a_verifier' end;
    v_motif := case when v.tentatives = 0 then 'Facture réglée avant toute tentative : aucun envoi.'
                    else 'Facture réglée pendant une reprise : envoi incertain, à vérifier.' end;
  elsif v.tentatives = 0 and v.created_at < v_maintenant
        - make_interval(hours => (v_param ->> 'reservation_sans_tentative_heures')::int) then
    v_statut := 'abandonnee';
    v_motif := 'Réservation expirée sans aucune tentative : aucun envoi.';
  elsif v.tentatives > 0 and v.compte_fournisseur is distinct from p_compte then
    v_statut := 'a_verifier';
    v_motif := 'Compte fournisseur différent de celui de la première tentative : protection anti-doublon non garantie, aucune reprise.';
  elsif v.tentatives > 0 and v_maintenant >= v.limite_reprise then
    v_statut := 'a_verifier';
    v_motif := 'Limite de reprise atteinte (20 h après la première tentative) : envoi incertain, aucune reprise.';
  elsif v.tentatives >= (v_param ->> 'tentatives_max')::int then
    v_statut := 'a_verifier';
    v_motif := 'Nombre maximal de tentatives atteint : envoi incertain.';
  end if;
  if v_statut is not null then
    perform public.relances_contexte('prendre');
    update public.relances
       set statut = v_statut, erreur = v_motif,
           historique = historique || public.relances_evenement(case when v_statut = 'abandonnee' then 'abandon' else 'a_verifier' end,
                                                                jsonb_build_object('motif', v_motif))
     where id = p_relance;
    perform public.relances_fin_contexte();
    return jsonb_build_object('action', 'rien', 'statut', v_statut, 'motif', v_motif);
  end if;
  if not public.relances_horaire_ouvre(v_maintenant) then
    return jsonb_build_object('action', 'attendre', 'statut', v.statut, 'motif', 'Hors des horaires d''envoi.');
  end if;
  perform public.relances_contexte('prendre');
  update public.relances
     set statut = 'en_cours', tentatives = tentatives + 1, derniere_tentative_le = v_maintenant,
         premiere_tentative_le = coalesce(premiere_tentative_le, v_maintenant),
         limite_reprise = coalesce(limite_reprise, v_maintenant + make_interval(hours => (v_param ->> 'limite_reprise_heures')::int)),
         compte_fournisseur = coalesce(compte_fournisseur, p_compte),
         historique = historique || public.relances_evenement('tentative', jsonb_build_object('numero', tentatives + 1))
   where id = p_relance
  returning * into v;
  perform public.relances_fin_contexte();
  return jsonb_build_object('action', 'envoyer', 'relance_id', v.id, 'tentative', v.tentatives,
    'requete', v.requete_fournisseur, 'requete_texte', v.requete_fournisseur::text, 'requete_empreinte', v.requete_empreinte,
    'cle_idempotence', v.cle_idempotence, 'pdf_chemin', f.pdf_chemin, 'pdf_empreinte', v.pdf_empreinte,
    'limite_reprise', v.limite_reprise);
end
$$;

-- 5c-bis. Verrou de l'IDENTIFIANT d'un email chez le fournisseur (verrou de transaction, sans table) : pris par la réception
--         d'un événement, l'enregistrement d'une réponse et le constat de l'administrateur, TOUJOURS avant le verrou de la
--         relance (même ordre partout : pas d'interblocage). Sans lui, un événement sans étiquette reçu pendant
--         l'enregistrement de la réponse resterait en attente jusqu'au balayage suivant (constaté en essai simultané).
create or replace function public.relances_verrou_identifiant(p_fournisseur_id text)
returns void
language sql
as $$
  select case when nullif(btrim(coalesce(p_fournisseur_id, '')), '') is not null
              then pg_advisory_xact_lock(hashtextextended('sgi-relances-email:' || btrim(p_fournisseur_id), 0)) end;
$$;

-- 5d. Résultat d'une tentative (réponse du fournisseur). Issues : « acceptee » (identifiant de l'email reçu),
--     « temporaire » (réessayer plus tard, même demande, même clé), « refus » (refus certain, aucun email),
--     « incertain » (à vérifier). Un résultat d'une tentative dépassée n'est retenu que s'il prouve l'acceptation.
create or replace function public.relances_resultat(p_relance uuid, p_tentative integer, p_issue text,
  p_fournisseur_id text, p_erreur text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v public.relances;
  v_maintenant timestamptz := public.relances_maintenant();
  v_erreur text := left(nullif(btrim(coalesce(p_erreur, '')), ''), 300);
  v_statut text;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  if p_issue not in ('acceptee', 'temporaire', 'refus', 'incertain') then
    raise exception 'Relance : issue « % » non prévue.', p_issue;
  end if;
  if public.relances_contient_secret(v_erreur) then
    v_erreur := 'Message d''erreur masqué (donnée sensible possible).';
  end if;
  perform public.relances_verrou_identifiant(p_fournisseur_id);
  select * into v from public.relances where id = p_relance for update;
  if not found then
    raise exception 'Relance introuvable.';
  end if;
  if p_issue = 'acceptee' then
    if coalesce(btrim(p_fournisseur_id), '') = '' then
      raise exception 'Relance : acceptation sans identifiant du fournisseur.';
    end if;
    if v.statut in ('acceptee', 'rejetee') then
      return jsonb_build_object('statut', v.statut, 'deja', true,
                                'anomalie', v.fournisseur_id is distinct from p_fournisseur_id);
    end if;
    if v.statut not in ('en_cours', 'a_verifier', 'abandonnee') or (v.fournisseur_id is not null and v.fournisseur_id <> p_fournisseur_id) then
      return jsonb_build_object('statut', v.statut, 'ignore', true);
    end if;
    perform public.relances_contexte('resultat');
    update public.relances
       set statut = 'acceptee', fournisseur_id = p_fournisseur_id, accepte_le = coalesce(accepte_le, v_maintenant),
           date_envoi = coalesce(date_envoi, v_maintenant), erreur = null,
           historique = historique || public.relances_evenement('acceptation',
             jsonb_build_object('tentative', p_tentative, 'fournisseur_id', p_fournisseur_id,
                                'apres', case when v.statut = 'en_cours' then null else v.statut end))
     where id = p_relance;
    perform public.relances_fin_contexte();
    -- Événements reçus avant l'enregistrement de cet identifiant : rapprochés maintenant (aucun envoi).
    return jsonb_build_object('statut', 'acceptee', 'evenements_rapproches', public.relances_rapprocher_relance(p_relance));
  end if;
  -- Issues sans acceptation : seulement pour la tentative en cours.
  if v.statut <> 'en_cours' or p_tentative is distinct from v.tentatives::integer then
    return jsonb_build_object('statut', v.statut, 'ignore', true);
  end if;
  v_statut := case p_issue when 'temporaire' then 'en_cours' when 'refus' then 'refusee' else 'a_verifier' end;
  perform public.relances_contexte('resultat');
  update public.relances
     set statut = v_statut, erreur = coalesce(v_erreur, 'Erreur sans message'),
         historique = historique || public.relances_evenement(p_issue,
           jsonb_build_object('tentative', p_tentative, 'erreur', coalesce(v_erreur, 'Erreur sans message')))
   where id = p_relance;
  perform public.relances_fin_contexte();
  return jsonb_build_object('statut', v_statut);
end
$$;

-- 5e. Événements de livraison : réception DURABLE (table relances_evenements), puis rapprochement.
-- 5e-1. Application d'un événement à SA relance (verrouillée par l'appelant). Jamais d'envoi, jamais de reprise : seuls
--        l'état, l'acceptation, la livraison et le rejet sont constatés ; un événement déjà présent dans l'historique de la
--        relance (y compris après la suppression de sa ligne) est sans effet ; aucun état ne régresse.
create or replace function public.relances_appliquer_evenement(p_evenement text, p_relance uuid)
returns text
language plpgsql
set search_path = public
as $$
declare
  e public.relances_evenements;
  v public.relances;
  v_statut text;
begin
  select * into e from public.relances_evenements where evenement_id = p_evenement;
  select * into v from public.relances where id = p_relance;
  if exists (select 1 from jsonb_array_elements(v.historique) x where x ->> 'evenement_id' = e.evenement_id) then
    return 'deja_applique';
  end if;
  v_statut := v.statut;
  if e.type in ('email.sent', 'email.delivered', 'email.bounced') and v.statut in ('en_cours', 'a_verifier', 'abandonnee') then
    v_statut := 'acceptee';
  end if;
  if e.type = 'email.bounced' and v.rebond_le is null then
    v_statut := 'rejetee';
  end if;
  perform public.relances_contexte('evenement');
  update public.relances
     set statut = v_statut,
         fournisseur_id = coalesce(fournisseur_id, e.fournisseur_id),
         accepte_le = case when v_statut in ('acceptee', 'rejetee') then coalesce(accepte_le, e.survenu_le) else accepte_le end,
         date_envoi = case when v_statut in ('acceptee', 'rejetee') then coalesce(date_envoi, e.survenu_le) else date_envoi end,
         livre_le = case when e.type = 'email.delivered' and v_statut <> 'rejetee' and v.rebond_le is null
                         then coalesce(livre_le, e.survenu_le) else livre_le end,
         rebond_le = case when e.type = 'email.bounced' then coalesce(rebond_le, e.survenu_le) else rebond_le end,
         rebond_motif = case when e.type = 'email.bounced' then coalesce(rebond_motif, e.detail, 'Rejet définitif') else rebond_motif end,
         historique = historique || public.relances_evenement('evenement',
           jsonb_build_object('evenement_id', e.evenement_id, 'type', e.type, 'survenu_le', e.survenu_le, 'detail', e.detail,
                              'recu_le', e.recu_le))
   where id = v.id;
  perform public.relances_fin_contexte();
  return 'applique';
end
$$;

-- 5e-2. Rapprochement d'UN événement en attente. Verrous : l'événement (ignoré s'il est déjà pris par un autre traitement),
--        puis la relance. Jamais appliqué — il reste en attente avec une ALERTE explicite — si : l'étiquette et
--        l'identifiant fournisseur désignent deux relances différentes ; la relance porte un autre identifiant ; elle n'a
--        jamais été tentée ; le compte fournisseur diffère ; elle a été refusée (aucun email) ; ou elle a été abandonnée
--        puis remplacée par une nouvelle relance du même rang.
create or replace function public.relances_rapprocher_evenement(p_evenement text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  e public.relances_evenements;
  v_tag uuid;
  v_id uuid;
  v_cible uuid;
  c public.relances;
  v_alerte text;
  v_application text;
begin
  select * into e from public.relances_evenements where evenement_id = p_evenement for update skip locked;
  if not found then
    return jsonb_build_object('resultat', 'occupe');
  end if;
  if e.statut <> 'en_attente' then
    return jsonb_build_object('resultat', e.statut, 'relance_id', e.relance_rapprochee);
  end if;
  if e.relance_id is not null then
    select id into v_tag from public.relances where id = e.relance_id;
  end if;
  if e.fournisseur_id is not null then
    select id into v_id from public.relances where fournisseur_id = e.fournisseur_id;
  end if;
  -- Conflit lu sur l'étiquette REÇUE (que la relance qu'elle désigne existe encore ou non).
  if e.relance_id is not null and v_id is not null and e.relance_id <> v_id then
    v_alerte := format('Conflit : l''étiquette désigne la relance %s et l''identifiant fournisseur la relance %s ; événement non appliqué.', e.relance_id, v_id);
  else
    v_cible := coalesce(v_id, v_tag);
    if v_cible is not null then
      select * into c from public.relances where id = v_cible for update;
      if c.fournisseur_id is not null and e.fournisseur_id is not null and c.fournisseur_id <> e.fournisseur_id then
        v_alerte := format('Conflit : la relance %s porte un autre identifiant fournisseur ; événement non appliqué.', c.id);
      elsif c.compte_fournisseur is null then
        v_alerte := format('La relance %s n''a jamais été tentée : événement non appliqué.', c.id);
      elsif c.compte_fournisseur <> e.compte_fournisseur then
        v_alerte := format('Compte fournisseur différent (événement : %s ; relance : %s) : événement non appliqué.',
                           e.compte_fournisseur, c.compte_fournisseur);
      elsif c.statut = 'refusee' then
        v_alerte := format('La relance %s a été refusée par le fournisseur (aucun email) : événement non appliqué.', c.id);
      elsif c.statut = 'abandonnee' and exists (select 1 from public.relances r where r.facture_id = c.facture_id
              and r.rang = c.rang and r.id <> c.id and r.statut not in ('abandonnee', 'refusee')) then
        v_alerte := format('La relance %s, abandonnée, a été remplacée par une nouvelle relance du même rang : à vérifier.', c.id);
      else
        v_application := public.relances_appliquer_evenement(e.evenement_id, c.id);
        perform public.relances_contexte('rapprocher');
        update public.relances_evenements
           set statut = 'rapproche', rapproche_le = public.relances_maintenant(), relance_rapprochee = c.id, alerte = null
         where evenement_id = e.evenement_id;
        perform public.relances_fin_contexte();
        return jsonb_build_object('resultat', 'rapproche', 'relance_id', c.id, 'application', v_application);
      end if;
    end if;
  end if;
  if v_alerte is distinct from e.alerte then
    perform public.relances_contexte('rapprocher');
    update public.relances_evenements set alerte = v_alerte where evenement_id = e.evenement_id;
    perform public.relances_fin_contexte();
  end if;
  return jsonb_build_object('resultat', 'en_attente', 'alerte', v_alerte);
end
$$;

-- 5e-3. Rapprochement des événements en attente d'UNE relance (dans l'ordre de leur date), appelé dès que son identifiant
--        fournisseur est connu (acceptation, constat de l'administrateur, événement étiqueté).
create or replace function public.relances_rapprocher_relance(p_relance uuid)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_ev record;
  v_n integer := 0;
begin
  for v_ev in
    select e.evenement_id from public.relances_evenements e, public.relances r
     where r.id = p_relance and e.statut = 'en_attente'
       and (e.relance_id = r.id or (r.fournisseur_id is not null and e.fournisseur_id = r.fournisseur_id))
     order by e.survenu_le, e.evenement_id
     for update of e skip locked
  loop
    if public.relances_rapprocher_evenement(v_ev.evenement_id) ->> 'resultat' = 'rapproche' then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end
$$;

-- 5e-4. Réception d'un événement signé (la route a vérifié la signature) : ENREGISTRÉ d'abord, puis rapproché si possible.
--        Même identifiant reçu deux fois : « déjà », rien ne change. Renvoyé après la suppression de sa ligne : réenregistré ;
--        rapproché d'une relance qui l'a déjà appliqué, il est sans effet ; ancien « sans suite » : de nouveau en attente.
create or replace function public.relances_recevoir_evenement(p_evenement_id text, p_type text, p_fournisseur_id text,
  p_relance uuid, p_survenu_le timestamptz, p_detail text, p_compte text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_detail text := left(nullif(btrim(coalesce(p_detail, '')), ''), 300);
  v_n integer;
  v_res jsonb;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  if coalesce(btrim(p_evenement_id), '') = '' or p_survenu_le is null or coalesce(p_type, '') !~ '^email\.[a-z_]{1,34}$'
     or (nullif(btrim(coalesce(p_fournisseur_id, '')), '') is null and p_relance is null) then
    raise exception 'Événement de livraison incomplet.';
  end if;
  if coalesce(p_compte, '') !~ '^[A-Za-z0-9._-]{3,64}$' or public.relances_contient_secret(p_compte) then
    raise exception 'Événement : référence du compte fournisseur absente ou mal formée (référence non secrète attendue).';
  end if;
  if public.relances_contient_secret(v_detail) then
    v_detail := 'Détail masqué (donnée sensible possible).';
  end if;
  -- Avant tout autre verrou : attend la fin d'un enregistrement de réponse portant le même identifiant.
  perform public.relances_verrou_identifiant(p_fournisseur_id);
  perform public.relances_contexte('recevoir');
  insert into public.relances_evenements (evenement_id, type, fournisseur_id, relance_id, compte_fournisseur, survenu_le, detail)
  values (btrim(p_evenement_id), p_type, nullif(btrim(coalesce(p_fournisseur_id, '')), ''), p_relance, p_compte, p_survenu_le, v_detail)
  on conflict (evenement_id) do nothing;
  get diagnostics v_n = row_count;
  perform public.relances_fin_contexte();
  if v_n = 0 then
    return jsonb_build_object('resultat', 'deja', 'statut',
      (select statut from public.relances_evenements where evenement_id = btrim(p_evenement_id)));
  end if;
  v_res := public.relances_rapprocher_evenement(btrim(p_evenement_id));
  if v_res ->> 'resultat' = 'rapproche' then
    perform public.relances_rapprocher_relance((v_res ->> 'relance_id')::uuid);
  end if;
  return v_res || jsonb_build_object('enregistre', true);
end
$$;

-- 5e-5. Balayage de tous les événements en attente (à chaque exécution des relances) : rattrape un rapprochement manqué
--        (réception et réponse du fournisseur simultanées, incident prolongé). Aucun envoi.
create or replace function public.relances_rapprocher_tout()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_ev record;
  v_res jsonb;
  v_examines integer := 0;
  v_rapproches integer := 0;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  for v_ev in select evenement_id from public.relances_evenements where statut = 'en_attente' order by survenu_le, evenement_id loop
    v_examines := v_examines + 1;
    v_res := public.relances_rapprocher_evenement(v_ev.evenement_id);
    if v_res ->> 'resultat' = 'rapproche' then
      v_rapproches := v_rapproches + 1;
      v_rapproches := v_rapproches + public.relances_rapprocher_relance((v_res ->> 'relance_id')::uuid);
    end if;
  end loop;
  return jsonb_build_object('examines', v_examines, 'rapproches', v_rapproches,
    'en_attente', (select count(*) from public.relances_evenements where statut = 'en_attente'),
    'alertes', (select count(*) from public.relances_evenements where statut = 'en_attente' and alerte is not null));
end
$$;

-- 5e-6. Classement « sans suite » d'un événement en attente (administrateur, motif obligatoire, tracé). Jamais automatique.
create or replace function public.relances_classer_evenement(p_admin uuid, p_evenement text, p_motif text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_nom text;
  v_statut text;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  v_nom := public.verifier_auteur_finance(p_admin);
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Classement : motif obligatoire (5 caractères au moins).';
  end if;
  select statut into v_statut from public.relances_evenements where evenement_id = p_evenement for update;
  if v_statut is null then
    raise exception 'Événement introuvable.';
  end if;
  if v_statut <> 'en_attente' then
    raise exception 'Classement : seul un événement en attente se classe sans suite.';
  end if;
  perform public.relances_contexte('classer');
  update public.relances_evenements
     set statut = 'sans_suite', classe_par = p_admin, classe_par_nom = v_nom, classe_le = public.relances_maintenant(),
         motif_classement = btrim(p_motif)
   where evenement_id = p_evenement;
  perform public.relances_fin_contexte();
  return jsonb_build_object('statut', 'sans_suite');
end
$$;

-- 5e-7. Nettoyage : événements rapprochés ou sans suite depuis plus de 30 jours (un événement en attente n'est JAMAIS
--        supprimé automatiquement). Un événement rapproché reste copié dans l'historique de sa relance.
create or replace function public.relances_purger_evenements()
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_n integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  perform public.relances_contexte('purge');
  delete from public.relances_evenements
   where (statut = 'rapproche' and rapproche_le < public.relances_maintenant() - interval '30 days')
      or (statut = 'sans_suite' and classe_le < public.relances_maintenant() - interval '30 days');
  get diagnostics v_n = row_count;
  perform public.relances_fin_contexte();
  return v_n;
end
$$;

-- 5e-8. Déclencheur de la table des événements : toutes les règles, quel que soit le chemin (tableau de bord compris).
create or replace function public.relances_evenements_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_op text := coalesce(current_setting('sgi.rel_operation', true), '');
begin
  if public.appel_utilisateur() then
    raise exception 'Événements : écriture directe interdite.';
  end if;
  if tg_op = 'DELETE' then
    if v_op = 'purge' and ((old.statut = 'rapproche' and old.rapproche_le < public.relances_maintenant() - interval '30 days')
                           or (old.statut = 'sans_suite' and old.classe_le < public.relances_maintenant() - interval '30 days')) then
      return old;
    end if;
    if coalesce(current_setting('sgi.fin_operation', true), '') = 'nettoyage_essais'
       and exists (select 1 from public.relances r where r.essai
                     and (r.id = old.relance_rapprochee or r.id = old.relance_id
                          or (old.fournisseur_id is not null and r.fournisseur_id = old.fournisseur_id))) then
      return old;
    end if;
    raise exception 'Un événement reçu ne se supprime pas (nettoyage : 30 jours après son rapprochement ou son classement).';
  end if;
  if tg_op = 'INSERT' then
    if v_op <> 'recevoir' or new.statut <> 'en_attente' or new.alerte is not null or new.rapproche_le is not null
       or new.relance_rapprochee is not null or new.classe_le is not null or new.classe_par is not null then
      raise exception 'Un événement naît uniquement de la réception par l''application.';
    end if;
    if public.relances_contient_secret(coalesce(new.detail, '') || ' ' || new.compte_fournisseur || ' ' || new.evenement_id) then
      raise exception 'Événement : un secret d''authentification ne doit jamais être enregistré.';
    end if;
    new.recu_le := public.relances_maintenant();
    return new;
  end if;
  if (new.evenement_id, new.type, new.fournisseur_id, new.relance_id, new.compte_fournisseur, new.survenu_le, new.detail, new.recu_le)
     is distinct from
     (old.evenement_id, old.type, old.fournisseur_id, old.relance_id, old.compte_fournisseur, old.survenu_le, old.detail, old.recu_le) then
    raise exception 'Événement : le contenu reçu ne se modifie jamais.';
  end if;
  if old.statut <> 'en_attente' then
    raise exception 'Événement déjà traité (%) : figé.', old.statut;
  end if;
  if not ((v_op = 'rapprocher' and new.statut in ('en_attente', 'rapproche') and new.classe_le is null)
          or (v_op = 'classer' and new.statut = 'sans_suite')) then
    raise exception 'Événement : changement réservé à l''application (rapprochement ou classement par l''administrateur).';
  end if;
  if public.relances_contient_secret(new.alerte) or public.relances_contient_secret(new.motif_classement) then
    raise exception 'Événement : un secret d''authentification ne doit jamais être enregistré.';
  end if;
  return new;
end
$$;
drop trigger if exists relances_evenements_controle on public.relances_evenements;
create trigger relances_evenements_controle before insert or update or delete on public.relances_evenements
  for each row execute function public.relances_evenements_controle();

-- 5f. Résolution par l'administrateur (motif obligatoire, tracée ; jamais de renvoi) :
--     « email_accepte » (constaté dans le tableau de bord du fournisseur, date de l'envoi constatée) ;
--     « aucun_envoi » (constaté : aucun email parti) ; « traitee » (refus ou rejet traité, ex. adresse corrigée).
--     Une demande en cours ne se résout qu'après 10 minutes sans tentative (jamais pendant un appel).
create or replace function public.relances_resoudre(p_admin uuid, p_relance uuid, p_constat text, p_motif text,
  p_date_envoi timestamptz, p_fournisseur_id text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v public.relances;
  v_nom text;
  v_maintenant timestamptz := public.relances_maintenant();
  v_statut text;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé à l''application (clé secrète)';
  end if;
  v_nom := public.verifier_auteur_finance(p_admin);
  if length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Résolution : motif obligatoire (5 caractères au moins).';
  end if;
  perform public.relances_verrou_identifiant(p_fournisseur_id);
  select * into v from public.relances where id = p_relance for update;
  if not found then
    raise exception 'Relance introuvable.';
  end if;
  if not ((v.statut in ('reservee', 'en_cours', 'a_verifier', 'refusee') and v.resolu_le is null)
          or (v.statut = 'rejetee' and (v.resolu_le is null or v.resolu_le < v.rebond_le))) then
    raise exception 'Résolution : cette relance ne bloque rien (déjà résolue ou terminée).';
  end if;
  if v.statut = 'en_cours'
     and v.derniere_tentative_le > v_maintenant - make_interval(mins => (public.relances_parametres() ->> 'reprise_minutes')::int) then
    raise exception 'Résolution : une tentative est peut-être en cours ; réessayez dans 10 minutes.';
  end if;
  if p_constat = 'email_accepte' then
    if v.statut not in ('en_cours', 'a_verifier') then
      raise exception 'Résolution : « email accepté » seulement pour une relance tentée dont l''envoi est incertain.';
    end if;
    if p_date_envoi is null or p_date_envoi > v_maintenant or p_date_envoi < v.premiere_tentative_le - interval '5 minutes' then
      raise exception 'Résolution : date d''envoi constatée absente ou incohérente avec les tentatives.';
    end if;
    v_statut := 'acceptee';
  elsif p_constat = 'aucun_envoi' then
    if v.statut not in ('reservee', 'en_cours', 'a_verifier') then
      raise exception 'Résolution : « aucun envoi » seulement pour une relance réservée, en cours ou à vérifier.';
    end if;
    v_statut := 'abandonnee';
  elsif p_constat = 'traitee' then
    if v.statut not in ('refusee', 'rejetee') then
      raise exception 'Résolution : « traitée » seulement pour une relance refusée ou rejetée.';
    end if;
    v_statut := v.statut;
  else
    raise exception 'Résolution : constat « % » non prévu.', p_constat;
  end if;
  perform public.relances_contexte('resolution');
  update public.relances
     set statut = v_statut,
         date_envoi = case when v_statut = 'acceptee' then p_date_envoi else date_envoi end,
         fournisseur_id = coalesce(fournisseur_id, nullif(btrim(coalesce(p_fournisseur_id, '')), '')),
         resolu_par = p_admin, resolu_par_nom = v_nom, resolu_le = v_maintenant, motif_resolution = btrim(p_motif),
         historique = historique || public.relances_evenement('resolution',
           jsonb_build_object('constat', p_constat, 'auteur', p_admin, 'auteur_nom', v_nom, 'motif', btrim(p_motif),
                              'statut_precedent', v.statut, 'date_envoi_constatee', p_date_envoi,
                              'resolution_precedente', case when v.resolu_le is null then null
                                else jsonb_build_object('le', v.resolu_le, 'par', v.resolu_par_nom, 'motif', v.motif_resolution) end))
   where id = p_relance;
  perform public.relances_fin_contexte();
  -- Identifiant fourni par le constat : les événements reçus pour cet email sont rapprochés (aucun envoi, aucune reprise).
  return jsonb_build_object('statut', v_statut, 'evenements_rapproches', public.relances_rapprocher_relance(p_relance));
end
$$;

-- 5g. Demandes à reprendre (réservées ou en cours), pour la route d'exécution.
create or replace function public.relances_a_reprendre()
returns setof uuid
language sql
stable
set search_path = public
as $$
  select id from public.relances where statut in ('reservee', 'en_cours') order by created_at;
$$;

-- 5h. Déclenchement par la future tâche Cron (NON créée ici) : appelle la route du site avec le secret partagé lu dans
--     Vault. Exécutable par le propriétaire (postgres, rôle des tâches Cron) SEULEMENT ; aucun droit pour les jetons ni
--     pour la clé secrète. Créée sans dépendre de Vault ni de pg_net (appels dynamiques) ; échoue explicitement si l'un
--     manque. Aucun secret dans la commande Cron, l'URL ou les messages.
create or replace function public.relances_declencher()
returns bigint
language plpgsql
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
  v_id bigint;
begin
  if to_regclass('vault.decrypted_secrets') is null then
    raise exception 'Relances : Vault n''est pas installé ; déclenchement impossible.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'net' and p.proname = 'http_post') then
    raise exception 'Relances : pg_net n''est pas installé ; déclenchement impossible.';
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v_secret using 'relances_secret_cron';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v_url using 'relances_url';
  if length(coalesce(v_secret, '')) < 32 then
    raise exception 'Relances : secret partagé « relances_secret_cron » absent de Vault ou trop court ; déclenchement impossible.';
  end if;
  if coalesce(v_url, '') !~ '^(https://[a-z0-9.-]+|http://127\.0\.0\.1:[0-9]+)/api/relances/executer$' then
    raise exception 'Relances : adresse « relances_url » absente de Vault ou non conforme ; déclenchement impossible.';
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := $4)'
     into v_id
    using v_url, '{}'::jsonb, jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret), 60000;
  return v_id;
end
$$;

-- 5i. Nettoyage des essais Finance : remplace la version Finance À L'IDENTIQUE, sauf les relances : celles des
--     factures d'ESSAI (toujours d'essai, la base recopie l'indicateur) sont supprimées avec elles au lieu de bloquer.
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
  v_nb_relances integer;
  v_nb_evenements integer;
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
     or exists (select 1 from public.relances where facture_id = any(v_factures) and not essai) then
    raise exception 'Nettoyage refusé : une donnée réelle est liée à une facture d''essai ; rien n''a été supprimé';
  end if;
  perform public.rh_fin_contexte();
  perform public.finance_contexte('nettoyage_essais', null, null);
  delete from public.relances_evenements e using public.relances r
   where r.facture_id = any(v_factures)
     and (e.relance_rapprochee = r.id or e.relance_id = r.id or (e.fournisseur_id is not null and e.fournisseur_id = r.fournisseur_id));
  get diagnostics v_nb_evenements = row_count;
  delete from public.relances where facture_id = any(v_factures);
  get diagnostics v_nb_relances = row_count;
  delete from public.temps where facture_id = any(v_factures);
  get diagnostics v_nb_temps = row_count;
  delete from public.factures where id = any(v_factures);
  delete from public.compteurs where cle ~ '^essai_facture_[0-9]{4}$';
  get diagnostics v_nb_compteurs = row_count;
  perform public.finance_fin_contexte();
  return jsonb_build_object('factures', cardinality(v_factures), 'temps', v_nb_temps, 'compteurs', v_nb_compteurs,
                            'relances', v_nb_relances, 'evenements', v_nb_evenements, 'pdf_chemins', to_jsonb(v_chemins));
end
$$;

-- Droits des fonctions : aucune n'est appelable avec un jeton utilisateur ni par un visiteur.
do $$
declare
  v_fonction text;
begin
  foreach v_fonction in array array[
    'relances_parametres()', 'relances_maintenant()', 'relances_jour(timestamptz)', 'relances_horaire_ouvre(timestamptz)',
    'relances_adresse_fictive(text)', 'relances_adresse_valide(text)', 'relances_contient_secret(text)',
    'relances_contexte(text)', 'relances_fin_contexte()', 'relances_evenement(text, jsonb)', 'relances_situation(uuid)',
    'relances_controle_requete(jsonb, uuid, uuid)', 'relances_controle()', 'relances_apercu()',
    'relances_reserver(uuid, uuid, integer, jsonb)', 'relances_prendre(uuid, text)',
    'relances_resultat(uuid, integer, text, text, text)', 'relances_verrou_identifiant(text)',
    'relances_appliquer_evenement(text, uuid)', 'relances_rapprocher_evenement(text)', 'relances_rapprocher_relance(uuid)',
    'relances_recevoir_evenement(text, text, text, uuid, timestamptz, text, text)', 'relances_rapprocher_tout()',
    'relances_classer_evenement(uuid, text, text)', 'relances_purger_evenements()', 'relances_evenements_controle()',
    'relances_resoudre(uuid, uuid, text, text, timestamptz, text)', 'relances_a_reprendre()',
    'relances_declencher()', 'supprimer_essais_finance()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    if v_fonction not in ('relances_controle()', 'relances_declencher()', 'relances_evenements_controle()') then
      execute format('grant execute on function public.%s to service_role', v_fonction);
    end if;
  end loop;
  -- Déclenchement : le propriétaire seulement (rôle des tâches Cron), pas même la clé secrète.
  execute 'revoke all on function public.relances_declencher() from service_role';
end
$$;

-- 6. Droits sur la table : AUCUN pour les jetons (même admin) ; l'écran lit avec la clé secrète après exigerAdmin.
--    Règle RLS de défense en profondeur : lecture admin (session active), jamais d'écriture.
do $$
declare
  v_regle record;
begin
  for v_regle in select policyname from pg_policies where schemaname = 'public' and tablename = 'relances' loop
    execute format('drop policy if exists %I on public.relances', v_regle.policyname);
  end loop;
end
$$;
create policy "relances_lecture_admin" on public.relances for select to authenticated using ((select public.est_admin()));
revoke all on public.relances from anon, authenticated;
-- Événements : mêmes droits (aucun pour les jetons, même admin ; règle de défense en lecture admin).
alter table public.relances_evenements enable row level security;
create policy "relances_evenements_lecture_admin" on public.relances_evenements for select to authenticated
  using ((select public.est_admin()));
revoke all on public.relances_evenements from public, anon, authenticated;
grant select, insert, update, delete on public.relances_evenements to service_role;

-- 7. Contrôles finaux et autotest (annulé) ----------------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_admin uuid;
  v_def_maintenant text;
  v_def_fictive text;
  v_client uuid;
  v_f1 uuid := gen_random_uuid();
  v_f2 uuid := gen_random_uuid();
  v_r1 uuid := gen_random_uuid();
  v_r2 uuid := gen_random_uuid();
  v_r3 uuid := gen_random_uuid();
  v_f3 uuid := gen_random_uuid();
  v_r4 uuid := gen_random_uuid();
  v_lundi timestamptz;   -- un lundi à 15 h en Martinique (19 h UTC), choisi d'après la date du jour : autotest indépendant
                         -- du moment où la migration s'applique (week-end, nuit)
  v_req jsonb;
  v_res jsonb;
  v_compte text := 'compte-autotest';
  v_avant text;
  v_apres text;
begin
  -- Fonctions appelables avec un jeton : toujours exactement les 4 fonctions d'identité ; aucune pour le visiteur.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Relances : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Relances : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'Relances : fonction(s) lisant le coût interne taux_horaire : %', v_liste;
  end if;
  select string_agg(tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'Relances : règles sans contrôle de session active : %', v_liste;
  end if;
  if has_table_privilege('authenticated', 'public.relances', 'select') or has_table_privilege('authenticated', 'public.relances', 'insert')
     or has_table_privilege('authenticated', 'public.relances', 'update') or has_table_privilege('authenticated', 'public.relances', 'delete')
     or has_table_privilege('anon', 'public.relances', 'select') or has_table_privilege('anon', 'public.relances', 'insert') then
    raise exception 'Relances : droits sur la table relances pour un jeton';
  end if;
  -- 14e table : aucun droit pour les jetons, RLS active, déclencheur posé, vide.
  if has_table_privilege('authenticated', 'public.relances_evenements', 'select')
     or has_table_privilege('authenticated', 'public.relances_evenements', 'insert')
     or has_table_privilege('authenticated', 'public.relances_evenements', 'update')
     or has_table_privilege('authenticated', 'public.relances_evenements', 'delete')
     or has_table_privilege('anon', 'public.relances_evenements', 'select') or has_table_privilege('anon', 'public.relances_evenements', 'insert')
     or not (select relrowsecurity from pg_class where oid = 'public.relances_evenements'::regclass)
     or not exists (select 1 from pg_trigger where tgname = 'relances_evenements_controle' and not tgisinternal)
     or exists (select 1 from public.relances_evenements) then
    raise exception 'Relances : table relances_evenements mal protégée ou non vide';
  end if;
  -- Déclenchement : propriétaire postgres, aucun autre rôle (ni PUBLIC, ni jetons, ni clé secrète).
  select pg_get_userbyid(p.proowner) into v_liste from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'relances_declencher';
  if v_liste is distinct from 'postgres' then
    raise exception 'Relances : relances_declencher appartient à % (postgres attendu)', coalesce(v_liste, 'personne');
  end if;
  if not has_function_privilege('postgres', 'public.relances_declencher()', 'execute')
     or has_function_privilege('anon', 'public.relances_declencher()', 'execute')
     or has_function_privilege('authenticated', 'public.relances_declencher()', 'execute')
     or has_function_privilege('service_role', 'public.relances_declencher()', 'execute')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                 where p.oid = 'public.relances_declencher()'::regprocedure and a.grantee = 0) then
    raise exception 'Relances : droits d''exécution de relances_declencher incorrects';
  end if;
  if not has_function_privilege('service_role', 'public.relances_reserver(uuid, uuid, integer, jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.relances_apercu()', 'execute') then
    raise exception 'Relances : fonctions de service non exécutables avec la clé secrète';
  end if;
  -- Un seul appel réseau possible dans tout le schéma : relances_declencher (dynamique).
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.prosrc ilike '%net.http%' or p.prosrc ilike '%http_request%') and p.proname <> 'relances_declencher';
  if v_liste is not null then
    raise exception 'Relances : fonction(s) appelant le réseau : %', v_liste;
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'relances_controle' and tgrelid = 'public.relances'::regclass and not tgisinternal) then
    raise exception 'Relances : déclencheur relances_controle absent';
  end if;
  if (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'relances'
        and column_name = 'date_envoi') <> 'YES'
     or (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'relances'
           and column_name = 'date_envoi') is not null then
    raise exception 'Relances : date_envoi doit être facultative et sans valeur par défaut';
  end if;
  -- Sans Vault ou sans pg_net, le déclenchement échoue explicitement (vérifié seulement si pg_net manque : jamais
  -- d'appel réseau pendant la migration).
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'net' and p.proname = 'http_post') then
    begin
      perform public.relances_declencher();
      raise exception 'AUTOTEST: déclenchement sans pg_net accepté';
    exception when others then
      if sqlerrm like 'AUTOTEST:%' then raise exception 'Relances : %', sqlerrm; end if;
      if sqlerrm not in ('Relances : Vault n''est pas installé ; déclenchement impossible.',
                         'Relances : pg_net n''est pas installé ; déclenchement impossible.') then
        raise exception 'Relances : message inattendu sans dépendance : %', sqlerrm;
      end if;
    end;
  end if;

  select md5(p.prosrc) into v_def_maintenant from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'relances_maintenant';
  select md5(p.prosrc) into v_def_fictive from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'relances_adresse_fictive';
  select md5(coalesce((select string_agg(r::text, '|' order by r.id) from public.relances r), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(c::text, '|' order by c.cle) from public.compteurs c), '')
          || coalesce((select string_agg(e::text, '|' order by e.evenement_id) from public.relances_evenements e), ''))
    into v_avant;
  select id into v_admin from public.profiles where role = 'admin' order by created_at limit 1;
  if v_admin is null then
    raise exception 'Relances : aucun compte admin, autotest impossible';
  end if;
  v_lundi := (date_trunc('week', now() at time zone 'UTC') + interval '7 days 19 hours') at time zone 'UTC';

  -- Autotest complet, annulé à la fin : factures, client et relances d'essai fictifs, AUCUN appel au fournisseur,
  -- aucun numéro consommé. L'heure est fixée (lundi 15 h en Martinique) et les adresses d'essai permises le temps de
  -- l'autotest seulement ; les définitions d'origine sont rétablies par l'annulation (contrôlées par empreinte ensuite).
  begin
    create or replace function public.relances_maintenant() returns timestamptz language sql stable
      as $f$ select current_setting('sgi.rel_autotest_maintenant')::timestamptz $f$;
    create or replace function public.relances_adresse_fictive(p_adresse text) returns boolean language sql immutable
      as $f$ select false $f$;
    perform set_config('sgi.rel_autotest_maintenant', v_lundi::text, true);

    insert into public.clients (nom, email_contact) values ('[ESSAI] Autotest relances', 'client-autotest@exemple.invalid')
      returning id into v_client;
    perform public.finance_contexte('emission', '{"action":"emission","test":"autotest_relances"}', v_f1);
    insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                                 instantane_emission, cle_emission)
    values (v_f1, v_client, 'AUTOTEST-REL-1', 'emise', true, public.relances_jour(v_lundi) - 40, public.relances_jour(v_lundi) - 40,
            100, 8.5, 108.5, '{}', gen_random_uuid());
    perform public.finance_contexte('pdf', '{"action":"pdf_archive","test":"autotest_relances"}', v_f1);
    update public.factures set pdf_statut = 'disponible', pdf_chemin = 'autotest/AUTOTEST-REL-1.pdf',
                               pdf_empreinte = repeat('e', 64), pdf_taille = 10, pdf_archive_le = now() where id = v_f1;
    perform public.finance_contexte('emission', '{"action":"emission","test":"autotest_relances"}', v_f2);
    insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                                 instantane_emission, cle_emission)
    values (v_f2, v_client, 'AUTOTEST-REL-2', 'emise', true, public.relances_jour(v_lundi) - 3, public.relances_jour(v_lundi) - 3,
            100, 8.5, 108.5, '{}', gen_random_uuid());
    perform public.finance_fin_contexte();

    v_req := jsonb_build_object('fournisseur', 'resend', 'version', 1, 'from', 'SG Ingénierie [ESSAI] <expediteur-autotest@exemple.invalid>',
      'to', 'destinataire-autotest@exemple.invalid', 'reply_to', null, 'subject', '[ESSAI] Facture AUTOTEST-REL-1 : rappel d''échéance',
      'text', 'Bonjour, la facture AUTOTEST-REL-1 reste impayée. Cordialement.',
      'piece_jointe', jsonb_build_object('nom', 'AUTOTEST-REL-1.pdf', 'type', 'application/pdf', 'empreinte', repeat('e', 64)),
      'tags', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', v_r1::text)));

    -- Situation : J+40, aucune relance → relance n° 1 due (jamais trois relances rapprochées : une à la fois).
    if (public.relances_situation(v_f1) ->> 'rang') is distinct from '1' then
      raise exception 'AUTOTEST: relance n° 1 non due à J+40 (%)', public.relances_situation(v_f1);
    end if;
    if coalesce(public.relances_situation(v_f2) ->> 'blocage', '') not like 'PDF archivé indisponible%' then
      raise exception 'AUTOTEST: facture sans PDF non signalée (%)', public.relances_situation(v_f2);
    end if;
    -- Écriture directe refusée ; demande contenant un secret refusée ; mauvaise pièce jointe refusée.
    begin
      insert into public.relances (facture_id, rang, requete_fournisseur) values (v_f1, 1, v_req);
      raise exception 'AUTOTEST: relance écrite directement';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    v_res := public.relances_reserver(v_r1, v_f1, 1,
      jsonb_set(v_req, '{text}', to_jsonb('Facture AUTOTEST-REL-1, Authorization: Bearer re_abcdefghijkl'::text)));
    raise exception 'AUTOTEST: demande contenant un secret acceptée (%)', v_res;
  exception when others then
    if sqlerrm not like 'Relance refusée : la demande contient un élément ressemblant à un secret%' then
      raise exception 'Relances : autotest en échec (premier bloc) : %', sqlerrm;
    end if;
  end;

  begin
    create or replace function public.relances_maintenant() returns timestamptz language sql stable
      as $f$ select current_setting('sgi.rel_autotest_maintenant')::timestamptz $f$;
    create or replace function public.relances_adresse_fictive(p_adresse text) returns boolean language sql immutable
      as $f$ select false $f$;
    perform set_config('sgi.rel_autotest_maintenant', v_lundi::text, true);
    insert into public.clients (nom, email_contact) values ('[ESSAI] Autotest relances', 'client-autotest@exemple.invalid')
      returning id into v_client;
    perform public.finance_contexte('emission', '{"action":"emission","test":"autotest_relances"}', v_f1);
    insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                                 instantane_emission, cle_emission)
    values (v_f1, v_client, 'AUTOTEST-REL-1', 'emise', true, public.relances_jour(v_lundi) - 40, public.relances_jour(v_lundi) - 40,
            100, 8.5, 108.5, '{}', gen_random_uuid());
    perform public.finance_contexte('pdf', '{"action":"pdf_archive","test":"autotest_relances"}', v_f1);
    update public.factures set pdf_statut = 'disponible', pdf_chemin = 'autotest/AUTOTEST-REL-1.pdf',
                               pdf_empreinte = repeat('e', 64), pdf_taille = 10, pdf_archive_le = now() where id = v_f1;
    perform public.finance_contexte('emission', '{"action":"emission","test":"autotest_relances"}', v_f3);
    insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                                 instantane_emission, cle_emission)
    values (v_f3, v_client, 'AUTOTEST-REL-3', 'emise', true, public.relances_jour(v_lundi) - 36, public.relances_jour(v_lundi) - 6,
            100, 8.5, 108.5, '{}', gen_random_uuid());
    perform public.finance_contexte('pdf', '{"action":"pdf_archive","test":"autotest_relances"}', v_f3);
    update public.factures set pdf_statut = 'disponible', pdf_chemin = 'autotest/AUTOTEST-REL-3.pdf',
                               pdf_empreinte = repeat('f', 64), pdf_taille = 10, pdf_archive_le = now() where id = v_f3;
    perform public.finance_fin_contexte();
    v_req := jsonb_build_object('fournisseur', 'resend', 'version', 1, 'from', 'SG Ingénierie [ESSAI] <expediteur-autotest@exemple.invalid>',
      'to', 'destinataire-autotest@exemple.invalid', 'reply_to', null, 'subject', '[ESSAI] Facture AUTOTEST-REL-1 : rappel d''échéance',
      'text', 'Bonjour, la facture AUTOTEST-REL-1 reste impayée. Cordialement.',
      'piece_jointe', jsonb_build_object('nom', 'AUTOTEST-REL-1.pdf', 'type', 'application/pdf', 'empreinte', repeat('e', 64)),
      'tags', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', v_r1::text)));
    -- Seuil exact : J+6, pas encore (relance n° 1 à J+7).
    if coalesce(public.relances_situation(v_f3) ->> 'blocage', '') not like 'Relance n° 1 prévue à J+7%' then
      raise exception 'AUTOTEST: seuil J+7 non respecté (%)', public.relances_situation(v_f3);
    end if;

    -- Réservation : statut « reservee », aucune date d'envoi ; rejouée = même réservation.
    v_res := public.relances_reserver(v_r1, v_f1, 1, v_req);
    if not coalesce((v_res ->> 'reservee')::boolean, false) then
      raise exception 'AUTOTEST: réservation refusée (%)', v_res;
    end if;
    if not coalesce((public.relances_reserver(v_r1, v_f1, 1, v_req) ->> 'deja')::boolean, false)
       or coalesce((select date_envoi is not null or statut is distinct from 'reservee'
                  or cle_idempotence is distinct from 'sgi-relance-' || v_r1
                  or requete_empreinte is distinct from encode(sha256(convert_to(v_req::text, 'UTF8')), 'hex')
             from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: réservation incohérente (date d''envoi posée, clé ou empreinte)';
    end if;
    -- Une seconde relance de la même facture est bloquée tant que la première n'est pas résolue.
    if coalesce(public.relances_situation(v_f1) ->> 'blocage', '') not like 'Relance n° 1 réservée%' then
      raise exception 'AUTOTEST: relance non résolue non bloquante (%)', public.relances_situation(v_f1);
    end if;
    -- Tentative : enregistrée avant l'appel, limite = première tentative + 20 h.
    v_res := public.relances_prendre(v_r1, v_compte);
    if v_res ->> 'action' is distinct from 'envoyer' or (v_res ->> 'tentative')::int is distinct from 1
       or coalesce((select limite_reprise is distinct from v_lundi + interval '20 hours' or statut is distinct from 'en_cours'
                  or date_envoi is not null from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: tentative mal enregistrée (%)', v_res;
    end if;
    -- Reprise trop tôt : attendre ; arrêt après acceptation puis reprise le LENDEMAIN avec la même demande.
    if public.relances_prendre(v_r1, v_compte) ->> 'action' is distinct from 'attendre' then
      raise exception 'AUTOTEST: reprise immédiate acceptée';
    end if;
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '14 hours')::text, true);  -- mardi 5 h
    if public.relances_prendre(v_r1, v_compte) ->> 'action' is distinct from 'attendre' then
      raise exception 'AUTOTEST: reprise hors des horaires acceptée';
    end if;
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '18 hours')::text, true);  -- mardi 9 h (limite : 11 h)
    -- Compte fournisseur changé : jamais de reprise.
    begin
      v_res := public.relances_prendre(v_r1, 'autre-compte-autotest');
      if v_res ->> 'statut' is distinct from 'a_verifier' then
        raise exception 'AUTOTEST: reprise avec un autre compte (%)', v_res;
      end if;
      raise exception 'AUTOTEST_COMPTE';
    exception when others then if sqlerrm <> 'AUTOTEST_COMPTE' then raise; end if; end;
    v_res := public.relances_prendre(v_r1, v_compte);
    if v_res ->> 'action' is distinct from 'envoyer' or v_res ->> 'requete_texte' is distinct from v_req::text then
      raise exception 'AUTOTEST: reprise sans la demande figée (%)', v_res;
    end if;
    -- Événement SANS étiquette arrivé avant l'enregistrement de l'identifiant : CONSERVÉ en attente, relance inchangée.
    v_res := public.relances_recevoir_evenement('evt-0', 'email.delivered', 'email-autotest-1', null, v_lundi + interval '18 hours', null, v_compte);
    if v_res ->> 'resultat' is distinct from 'en_attente'
       or (select statut from public.relances_evenements where evenement_id = 'evt-0') is distinct from 'en_attente'
       or coalesce((select fournisseur_id is not null or livre_le is not null or jsonb_array_length(historique) <> 3
                      from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: événement précoce sans étiquette mal traité (%)', v_res;
    end if;
    -- Même événement reçu deux fois : « déjà », une seule ligne.
    if public.relances_recevoir_evenement('evt-0', 'email.delivered', 'email-autotest-1', null, v_lundi + interval '18 hours', null, v_compte)
         ->> 'resultat' is distinct from 'deja' then
      raise exception 'AUTOTEST: événement en double non reconnu';
    end if;
    -- Acceptation enregistrée : l'événement conservé est rapproché aussitôt (aucun envoi).
    v_res := public.relances_resultat(v_r1, 2, 'acceptee', 'email-autotest-1', null);
    if (v_res ->> 'evenements_rapproches')::int is distinct from 1
       or (select statut from public.relances_evenements where evenement_id = 'evt-0') is distinct from 'rapproche'
       or coalesce((select livre_le is distinct from v_lundi + interval '18 hours' or tentatives <> 2 from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: événement conservé non rapproché à l''acceptation (%)', v_res;
    end if;
    -- Étiquette et identifiant désignant deux relances différentes : non appliqué, en attente avec alerte.
    v_res := public.relances_recevoir_evenement('evt-conflit', 'email.bounced', 'email-autotest-1', v_r4, v_lundi + interval '18 hours 2 minutes', null, v_compte);
    if v_res ->> 'resultat' is distinct from 'en_attente' or coalesce(v_res ->> 'alerte', '') not like 'Conflit :%'
       or coalesce((select rebond_le is not null from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: conflit étiquette / identifiant appliqué (%)', v_res;
    end if;
    -- Autre compte fournisseur : non appliqué, en attente avec alerte.
    v_res := public.relances_recevoir_evenement('evt-compte', 'email.bounced', 'email-autotest-1', null, v_lundi + interval '18 hours 3 minutes', null, 'autre-compte');
    if coalesce(v_res ->> 'alerte', '') not like 'Compte fournisseur différent%'
       or coalesce((select rebond_le is not null from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: événement d''un autre compte appliqué (%)', v_res;
    end if;
    -- Référence de compte ressemblant à une clé : refusée (rien enregistré), même sans aucune relance correspondante.
    begin
      perform public.relances_recevoir_evenement('evt-cle', 'email.sent', 'email-autotest-inconnu', null, v_lundi, null, 're_cleautotest123');
      raise exception 'AUTOTEST: référence de compte secrète acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    if exists (select 1 from public.relances_evenements where evenement_id = 'evt-cle') then
      raise exception 'AUTOTEST: référence de compte secrète acceptée';
    end if;
    -- Acceptée aujourd'hui (mardi) : aucune autre relance de cette facture aujourd'hui, et 8 jours d'écart.
    if coalesce((select date_envoi is distinct from v_lundi + interval '18 hours' or statut is distinct from 'acceptee'
                   from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: acceptation mal datée';
    end if;
    if coalesce(public.relances_situation(v_f1) ->> 'blocage', '') not like 'Écart minimal de 8 jours%' then
      raise exception 'AUTOTEST: écart minimal non appliqué (%)', public.relances_situation(v_f1);
    end if;
    -- Garde-fou quotidien : relance n° 1 de f3 (J+7 ce mardi) tentée puis constatée « aucun envoi » : rien d'autre aujourd'hui.
    if (public.relances_situation(v_f3) ->> 'rang') is distinct from '1' then
      raise exception 'AUTOTEST: relance n° 1 non due à J+7 (%)', public.relances_situation(v_f3);
    end if;
    perform public.relances_reserver(v_r4, v_f3, 1, jsonb_build_object('fournisseur', 'resend', 'version', 1,
      'from', 'SG Ingénierie [ESSAI] <expediteur-autotest@exemple.invalid>', 'to', 'destinataire-autotest@exemple.invalid',
      'reply_to', null, 'subject', '[ESSAI] Facture AUTOTEST-REL-3 : rappel d''échéance',
      'text', 'Bonjour, la facture AUTOTEST-REL-3 reste impayée. Cordialement.',
      'piece_jointe', jsonb_build_object('nom', 'AUTOTEST-REL-3.pdf', 'type', 'application/pdf', 'empreinte', repeat('f', 64)),
      'tags', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', v_r4::text))));
    perform public.relances_prendre(v_r4, v_compte);
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '18 hours 11 minutes')::text, true);
    perform public.relances_resoudre(v_admin, v_r4, 'aucun_envoi', 'Aucun email chez le fournisseur', null, null);
    if coalesce(public.relances_situation(v_f3) ->> 'blocage', '') not like 'Une relance a déjà été réservée, tentée ou acceptée aujourd''hui%' then
      raise exception 'AUTOTEST: garde-fou quotidien non appliqué (%)', public.relances_situation(v_f3);
    end if;
    -- Demande figée : jamais modifiée, même dans un contexte de l'application.
    begin
      perform public.relances_contexte('evenement');
      update public.relances set objet = 'Autre objet', historique = historique || '[{}]' where id = v_r1;
      raise exception 'AUTOTEST: demande figée modifiée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.relances_fin_contexte();
    -- Historique : ajout seul (réécriture refusée).
    begin
      perform public.relances_contexte('evenement');
      update public.relances set historique = '[{"action":"faux"},{},{},{},{},{}]' where id = v_r1;
      raise exception 'AUTOTEST: historique réécrit';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.relances_fin_contexte();
    -- Événements en double, en retard, dans le désordre : un rejet définitif n'est jamais effacé.
    perform public.relances_recevoir_evenement('evt-1', 'email.bounced', 'email-autotest-1', null, v_lundi + interval '18 hours 1 minute', 'Boîte inexistante', v_compte);
    perform public.relances_recevoir_evenement('evt-2', 'email.delivered', 'email-autotest-1', null, v_lundi + interval '18 hours', null, v_compte);
    perform public.relances_recevoir_evenement('evt-1', 'email.bounced', 'email-autotest-1', null, v_lundi + interval '18 hours 1 minute', 'Boîte inexistante', v_compte);
    perform public.relances_recevoir_evenement('evt-3', 'email.sent', 'email-autotest-1', null, v_lundi + interval '18 hours', null, v_compte);
    if coalesce((select statut is distinct from 'rejetee' or livre_le is distinct from v_lundi + interval '18 hours' or rebond_le is null
              or (select count(*) from jsonb_array_elements(historique) e where e ->> 'action' = 'evenement') <> 4
          from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: événements de livraison mal traités';
    end if;
    -- Nettoyage à 30 jours : rapprochés supprimés, en attente JAMAIS ; renvoi d'un événement supprimé : sans effet.
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '20 days')::text, true);
    if public.relances_purger_evenements() <> 0 then
      raise exception 'AUTOTEST: événements supprimés avant 30 jours';
    end if;
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '40 days')::text, true);
    if public.relances_purger_evenements() <> 4
       or (select count(*) from public.relances_evenements where evenement_id in ('evt-conflit', 'evt-compte') and statut = 'en_attente') <> 2 then
      raise exception 'AUTOTEST: nettoyage des événements incorrect';
    end if;
    v_res := public.relances_recevoir_evenement('evt-1', 'email.bounced', 'email-autotest-1', null, v_lundi + interval '18 hours 1 minute', 'Boîte inexistante', v_compte);
    if v_res ->> 'application' is distinct from 'deja_applique'
       or coalesce((select (select count(*) from jsonb_array_elements(historique) e where e ->> 'action' = 'evenement') <> 4
                      from public.relances where id = v_r1), true) then
      raise exception 'AUTOTEST: événement renvoyé après suppression réappliqué (%)', v_res;
    end if;
    -- Rejet : bloque la relance suivante, même 7 jours plus tard ; résolution admin motivée la débloque ; l'écart de
    -- 8 jours depuis l'acceptation s'applique ensuite (7 jours : pas encore ; 8 jours : due).
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '7 days 18 hours')::text, true);
    if coalesce(public.relances_situation(v_f1) ->> 'blocage', '') not like 'Relance n° 1 rejetée%' then
      raise exception 'AUTOTEST: rejet non bloquant (%)', public.relances_situation(v_f1);
    end if;
    perform public.relances_resoudre(v_admin, v_r1, 'traitee', 'Adresse du client corrigée', null, null);
    if coalesce(public.relances_situation(v_f1) ->> 'blocage', '') not like 'Écart minimal de 8 jours%' then
      raise exception 'AUTOTEST: écart de 8 jours non respecté à 7 jours (%)', public.relances_situation(v_f1);
    end if;
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '9 days')::text, true);
    if (public.relances_situation(v_f1) ->> 'rang') is distinct from '2' then
      raise exception 'AUTOTEST: relance n° 2 non due après résolution (%)', public.relances_situation(v_f1);
    end if;
    -- Relance n° 2 : tentative, incertaine (limite dépassée) → à vérifier, jamais renvoyée ; bloque le lendemain.
    v_req := jsonb_set(jsonb_set(v_req, '{tags}', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', v_r2::text))),
                       '{subject}', to_jsonb('[ESSAI] Facture AUTOTEST-REL-1 : second rappel'::text));
    v_res := public.relances_reserver(v_r2, v_f1, 2, v_req);
    perform public.relances_prendre(v_r2, v_compte);
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '9 days 20 hours')::text, true);
    v_res := public.relances_prendre(v_r2, v_compte);
    if v_res ->> 'statut' is distinct from 'a_verifier' then
      raise exception 'AUTOTEST: limite de reprise non appliquée (%)', v_res;
    end if;
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '10 days')::text, true);
    if coalesce(public.relances_situation(v_f1) ->> 'blocage', '') not like 'Relance n° 2 à vérifier%' then
      raise exception 'AUTOTEST: relance incertaine non bloquante le lendemain (%)', public.relances_situation(v_f1);
    end if;
    -- Une résolution sans motif est refusée ; avec motif, tracée.
    begin
      perform public.relances_resoudre(v_admin, v_r2, 'aucun_envoi', '', null, null);
      raise exception 'AUTOTEST: résolution sans motif';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.relances_resoudre(v_admin, v_r2, 'email_accepte', 'Email visible dans le tableau de bord Resend',
                                     v_lundi + interval '9 days', 'email-autotest-2');
    if coalesce((select statut is distinct from 'acceptee' or date_envoi is distinct from v_lundi + interval '9 days'
                  or resolu_par is distinct from v_admin from public.relances where id = v_r2), true) then
      raise exception 'AUTOTEST: résolution « email accepté » mal enregistrée';
    end if;
    -- Une valeur constatée ne change jamais ; une relance ne se supprime pas.
    begin
      perform public.relances_contexte('evenement');
      update public.relances set date_envoi = now(), historique = historique || '[{}]' where id = v_r2;
      raise exception 'AUTOTEST: date d''envoi modifiée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.relances_fin_contexte();
    begin
      delete from public.relances where id = v_r2;
      raise exception 'AUTOTEST: relance supprimée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    -- Facture réglée avant toute tentative : la réservation est abandonnée, sans envoi.
    perform set_config('sgi.rel_autotest_maintenant', (v_lundi + interval '17 days')::text, true);
    v_req := jsonb_set(jsonb_set(v_req, '{tags}', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', v_r3::text))),
                       '{subject}', to_jsonb('[ESSAI] Facture AUTOTEST-REL-1 : dernier rappel avant contact direct'::text));
    v_res := public.relances_reserver(v_r3, v_f1, 3, v_req);
    if not coalesce((v_res ->> 'reservee')::boolean, false) then
      raise exception 'AUTOTEST: relance n° 3 refusée (%)', v_res;
    end if;
    perform public.finance_contexte('envoi', '{"action":"envoi","test":"autotest_relances"}', v_f1);
    update public.factures set statut = 'envoyee', date_envoi = now() where id = v_f1;
    perform public.finance_contexte('reglement', '{"action":"reglement","test":"autotest_relances"}', v_f1);
    update public.factures set statut = 'payee', date_reglement = current_date, mode_reglement = 'virement' where id = v_f1;
    perform public.finance_fin_contexte();
    if public.relances_prendre(v_r3, v_compte) ->> 'statut' is distinct from 'abandonnee' then
      raise exception 'AUTOTEST: relance d''une facture réglée non abandonnée';
    end if;
    -- Nettoyage des essais : factures d'essai et leurs relances supprimées.
    v_res := public.supprimer_essais_finance();
    if exists (select 1 from public.relances where facture_id in (v_f1, v_f2, v_f3)) or (v_res ->> 'relances')::int is distinct from 4
       or exists (select 1 from public.relances_evenements) or (v_res ->> 'evenements')::int is distinct from 3 then
      raise exception 'AUTOTEST: nettoyage des relances d''essai incomplet (%)', v_res;
    end if;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'Relances : autotest en échec : %', sqlerrm;
    end if;
  end;
  -- Définitions d'origine rétablies (heure réelle, adresses fictives refusées), contexte vide, données inchangées.
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'relances_maintenant') is distinct from v_def_maintenant
     or (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'relances_adresse_fictive') is distinct from v_def_fictive
     or not public.relances_adresse_fictive('quelquun@exemple.invalid')
     or public.relances_maintenant() is distinct from now() then
    raise exception 'Relances : définitions d''origine non rétablies après l''autotest';
  end if;
  if coalesce(current_setting('sgi.rel_operation', true), '') <> '' or coalesce(current_setting('sgi.fin_operation', true), '') <> '' then
    raise exception 'Relances : contexte resté actif après l''autotest';
  end if;
  select md5(coalesce((select string_agg(r::text, '|' order by r.id) from public.relances r), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(c::text, '|' order by c.cle) from public.compteurs c), '')
          || coalesce((select string_agg(e::text, '|' order by e.evenement_id) from public.relances_evenements e), ''))
    into v_apres;
  if v_apres is distinct from v_avant then
    raise exception 'Relances : l''autotest a modifié des données réelles';
  end if;
end
$$;
