-- Comptes de la base d'ESSAI pour les tests navigateur (mots de passe en clair : base locale uniquement).
alter table auth.users add column if not exists mot_de_passe text;
update auth.users set mot_de_passe = 'Essai-Admin-2026!' where email = 'sgi@gmx.fr';
insert into auth.users (id, email, mot_de_passe) values
  ('aaaaaaaa-0000-0000-0000-0000000000b2', 'manager@exemple.invalid', 'Essai-Manager-2026!'),
  ('aaaaaaaa-0000-0000-0000-0000000000b3', 'collab@exemple.invalid', 'Essai-Collab-2026!');
update public.profiles set role = 'manager', nom = 'Manager d''essai', collaborateur_id = '22222222-2222-2222-2222-222222222222'
 where email = 'manager@exemple.invalid';
update public.profiles set role = 'collaborateur', nom = 'Collaboratrice d''essai', collaborateur_id = '22222222-2222-2222-2222-222222222221'
 where email = 'collab@exemple.invalid';
