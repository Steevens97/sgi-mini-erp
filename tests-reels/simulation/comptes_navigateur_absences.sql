-- Données du test navigateur Absences (base d'ESSAI locale uniquement ; à rejouer APRÈS comptes_navigateur.sql).
-- Fiche de l'admin, un manager HORS équipe (Karim) et une seconde collaboratrice (Chloé Nguyen, même équipe que Léa).
\set ON_ERROR_STOP 1
insert into public.collaborateurs (id, nom, prenom, email, taux_horaire) values
  ('22222222-2222-2222-2222-2222222222fa', 'Admin', 'Sgi', 'sgi-fiche@exemple.fr', 0),
  ('22222222-2222-2222-2222-2222222222c1', 'Petit', 'Karim', 'karim@exemple.fr', 0);
update public.profiles set collaborateur_id = '22222222-2222-2222-2222-2222222222fa' where email = 'sgi@gmx.fr';
insert into auth.users (id, email, mot_de_passe) values
  ('aaaaaaaa-0000-0000-0000-0000000000b4', 'karim@exemple.invalid', 'Essai-Karim-2026!'),
  ('aaaaaaaa-0000-0000-0000-0000000000b5', 'chloe@exemple.invalid', 'Essai-Chloe-2026!');
update public.profiles set role = 'manager', nom = 'Karim (hors équipe)', collaborateur_id = '22222222-2222-2222-2222-2222222222c1'
 where email = 'karim@exemple.invalid';
update public.profiles set role = 'collaborateur', nom = 'Chloé d''essai', collaborateur_id = '22222222-2222-2222-2222-222222222223'
 where email = 'chloe@exemple.invalid';
