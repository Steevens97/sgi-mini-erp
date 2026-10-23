-- Compatibilité de l'écran Utilisateurs ACTUEL (code de main) avec la base, appel par appel, avec les
-- mêmes droits que l'application (jeton admin, clé secrète). Base d'ESSAI locale uniquement.
-- À lancer sur les six migrations seules, puis avec la migration Commercial : les résultats doivent être
-- identiques et tous « OK ».
-- Usage : JUSQUA=20261023130000 rejouer.sh tests_compat_utilisateurs.sql ; rejouer.sh tests_compat_utilisateurs.sql
\set ON_ERROR_STOP 0
\pset tuples_only on
\pset format unaligned
create schema compat;
create table compat.r (n serial, libelle text, ok boolean, detail text);
grant usage on schema compat to authenticated, service_role;
grant all on compat.r to authenticated, service_role;
grant usage on sequence compat.r_n_seq to authenticated, service_role;
create function compat.essai(p_libelle text, p_sql text, p_attendu text) returns void language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  insert into compat.r (libelle, ok, detail) values (p_libelle, v is not distinct from p_attendu, coalesce(v, 'null'));
exception when others then
  insert into compat.r (libelle, ok, detail) values (p_libelle, p_attendu = 'REFUS', 'refus : ' || sqlerrm);
end $$;
grant execute on function compat.essai(text, text, text) to authenticated, service_role;

-- Comptes : admin (sgi), session ouverte ; un compte « collaborateur » à rattacher.
insert into auth.sessions (id, user_id) values ('bbbbbbbb-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111');
select set_config('request.jwt.claims', json_build_object('sub', '11111111-1111-1111-1111-111111111111',
  'role', 'authenticated', 'session_id', 'bbbbbbbb-0000-0000-0000-0000000000a1')::text, false);

-- Création d'un compte (auth.admin.createUser) : dans Supabase, c'est le service d'authentification
-- (rôle propriétaire) qui écrit dans auth.users, pas la clé secrète ; le déclencheur réel crée le profil.
select compat.essai('création de compte : profil créé par le déclencheur, rôle collaborateur',
  $q$with u as (insert into auth.users (id, email) values ('cccccccc-0000-0000-0000-0000000000a2', 'compat@exemple.invalid') returning id)
     select count(*)::text from u$q$, '1');
select compat.essai('création de compte : profil bien présent après coup',
  $q$select role from public.profiles where id = 'cccccccc-0000-0000-0000-0000000000a2'$q$, 'collaborateur');

set role authenticated;
-- Page : liste des fiches et des profils (jeton admin)
select compat.essai('page : fiches lisibles (id, nom, prenom, email, poste)',
  $q$select count(*)::text from public.collaborateurs$q$, '3');
select compat.essai('page : profils lisibles par l''admin',
  $q$select count(*)::text from (select id, email, nom, role, collaborateur_id from public.profiles) p$q$, '2');
select compat.essai('taux horaire toujours illisible avec un jeton admin',
  $q$select taux_horaire::text from public.collaborateurs limit 1$q$, 'REFUS');
-- creerFiche : contrôle du doublon d'email, insertion avec taux, rattachement à son propre compte
select compat.essai('creerFiche : recherche de doublon par email',
  $q$select count(*)::text from public.collaborateurs where email ilike 'nouvelle@exemple.invalid'$q$, '0');
select compat.essai('creerFiche : création d''une fiche avec taux horaire (admin)',
  $q$with f as (insert into public.collaborateurs (id, nom, prenom, email, poste, date_entree, taux_horaire)
     values ('dddddddd-0000-0000-0000-0000000000a3', 'Compat', 'Nouvelle', 'nouvelle@exemple.invalid', 'Test', '2026-10-01', 80.5)
     returning id) select count(*)::text from f$q$, '1');
select compat.essai('creerFiche : rattachement de la fiche au compte de l''admin',
  $q$with p as (update public.profiles set collaborateur_id = 'dddddddd-0000-0000-0000-0000000000a3'
     where id = '11111111-1111-1111-1111-111111111111' returning id) select count(*)::text from p$q$, '1');
-- rattacherCompte : fiche → autre compte, puis détachement
select compat.essai('rattacherCompte : rattacher le compte créé à une fiche existante',
  $q$with p as (update public.profiles set collaborateur_id = '22222222-2222-2222-2222-222222222223'
     where id = 'cccccccc-0000-0000-0000-0000000000a2' returning id) select count(*)::text from p$q$, '1');
-- changerRole : par le jeton admin
select compat.essai('changerRole : collaborateur → manager',
  $q$with p as (update public.profiles set role = 'manager' where id = 'cccccccc-0000-0000-0000-0000000000a2' returning role)
     select string_agg(role, ',') from p$q$, 'manager');
select compat.essai('changerRole : l''admin ne peut pas se rétrograder lui-même',
  $q$update public.profiles set role = 'collaborateur' where id = '11111111-1111-1111-1111-111111111111' returning role$q$, 'REFUS');
reset role;
-- creerAcces : mise à jour du profil par la clé secrète
set role service_role;
select compat.essai('creerAcces : profil complété par la clé secrète (rôle, fiche, nom, email)',
  $q$with p as (update public.profiles set role = 'collaborateur', collaborateur_id = '22222222-2222-2222-2222-222222222223',
     nom = 'Chloe Nguyen', email = 'compat@exemple.invalid' where id = 'cccccccc-0000-0000-0000-0000000000a2' returning id)
     select count(*)::text from p$q$, '1');
select compat.essai('taux horaire lisible par la clé secrète (écran d''édition admin)',
  $q$select taux_horaire::text from public.collaborateurs where id = 'dddddddd-0000-0000-0000-0000000000a3'$q$, '80.50');
reset role;
-- revoquerAcces (auth.admin.deleteUser, service d'authentification) : profil supprimé en cascade, fiche conservée
select compat.essai('revoquerAcces : compte supprimé, fiche conservée',
  $q$with u as (delete from auth.users where id = 'cccccccc-0000-0000-0000-0000000000a2' returning id)
     select (select count(*) from u)::text$q$, '1');
select compat.essai('après révocation : profil disparu, fiche Nguyen conservée',
  $q$select (select count(*) from public.profiles where id = 'cccccccc-0000-0000-0000-0000000000a2')
     || '/' || (select count(*) from public.collaborateurs where id = '22222222-2222-2222-2222-222222222223')$q$, '0/1');
-- Page RH actuelle : un manager voit toutes les fiches, sans le taux
insert into auth.users (id, email) values ('cccccccc-0000-0000-0000-0000000000a4', 'manager-compat@exemple.invalid');
update public.profiles set role = 'manager', collaborateur_id = '22222222-2222-2222-2222-222222222222'
 where id = 'cccccccc-0000-0000-0000-0000000000a4';
insert into auth.sessions (id, user_id) values ('bbbbbbbb-0000-0000-0000-0000000000a4', 'cccccccc-0000-0000-0000-0000000000a4');
select set_config('request.jwt.claims', json_build_object('sub', 'cccccccc-0000-0000-0000-0000000000a4',
  'role', 'authenticated', 'session_id', 'bbbbbbbb-0000-0000-0000-0000000000a4')::text, false);
set role authenticated;
select compat.essai('page RH : le manager voit toutes les fiches',
  $q$select count(*)::text from (select id, prenom, nom, poste, email from public.collaborateurs) c$q$, '4');
select compat.essai('page RH : le manager ne crée pas de fiche',
  $q$insert into public.collaborateurs (nom) values ('Intrus') returning id$q$, 'REFUS');
reset role;

select n || '. [' || case when ok then 'OK ' else 'ÉCHEC' end || '] ' || libelle || '  (' || detail || ')' from compat.r order by n;
select 'BILAN : ' || count(*) filter (where ok) || '/' || count(*) || ' contrôles réussis' from compat.r;
