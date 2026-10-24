-- Comptes supplémentaires pour le test navigateur RH (base d'ESSAI locale uniquement ; à rejouer APRÈS
-- comptes_navigateur.sql). Manager d'essai = fiche Dubois (équipe : Moreau, Nguyen) ;
-- collaboratrice d'essai = fiche Moreau ; ajout : Nguyen (même équipe) et un manager hors équipe.
insert into public.collaborateurs (id, nom, prenom, email, poste, taux_horaire) values
  ('22222222-2222-2222-2222-2222222222b4', 'Horsequipe', 'Hugo', 'hugo@exemple.invalid', 'Manager', 110);
insert into auth.users (id, email, mot_de_passe) values
  ('aaaaaaaa-0000-0000-0000-0000000000b4', 'chloe@exemple.invalid', 'Essai-Chloe-2026!'),
  ('aaaaaaaa-0000-0000-0000-0000000000b5', 'hugo@exemple.invalid', 'Essai-Hugo-2026!');
update public.profiles set role = 'collaborateur', nom = 'Chloé (essai)', collaborateur_id = '22222222-2222-2222-2222-222222222223'
 where email = 'chloe@exemple.invalid';
update public.profiles set role = 'manager', nom = 'Hugo (essai, hors équipe)', collaborateur_id = '22222222-2222-2222-2222-2222222222b4'
 where email = 'hugo@exemple.invalid';
update public.profiles set nom = 'Admin d''essai' where email = 'sgi@gmx.fr';
