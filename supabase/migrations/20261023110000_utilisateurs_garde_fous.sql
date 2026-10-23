-- Module Utilisateurs : garde-fou « dernier administrateur ».
-- Empêche, en base, de retirer le rôle admin au dernier administrateur ou de supprimer
-- son profil (la suppression d'un compte supprime son profil en cascade : elle est donc
-- bloquée aussi). S'applique à tout le monde, y compris la clé secrète.

create or replace function public.proteger_dernier_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nb_admins integer;
begin
  if old.role is distinct from 'admin' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and new.role = 'admin' then
    return new;
  end if;

  select count(*) into v_nb_admins from public.profiles where role = 'admin';
  if v_nb_admins <= 1 then
    raise exception 'Impossible : ce compte est le dernier administrateur';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end
$$;

drop trigger if exists profiles_proteger_dernier_admin on public.profiles;
create trigger profiles_proteger_dernier_admin
  before update or delete on public.profiles
  for each row execute function public.proteger_dernier_admin();

-- Contrôles : le déploiement échoue si l'un d'eux ne passe pas.
do $$
declare
  v_nb integer;
  v_bloque boolean;
begin
  select count(*) into v_nb
    from pg_trigger
   where tgrelid = 'public.profiles'::regclass and tgname = 'profiles_proteger_dernier_admin';
  if v_nb <> 1 then
    raise exception 'Utilisateurs : le garde-fou du dernier administrateur est absent';
  end if;

  select count(*) into v_nb from public.profiles where role = 'admin';
  if v_nb < 1 then
    raise exception 'Utilisateurs : aucun administrateur dans profiles';
  end if;

  -- Essai réel, annulé aussitôt : rétrograder TOUS les admins doit échouer.
  v_bloque := false;
  begin
    update public.profiles set role = 'collaborateur' where role = 'admin';
  exception when others then
    v_bloque := true;
  end;
  if not v_bloque then
    raise exception 'Utilisateurs : rétrograder tous les administrateurs n''a pas été bloqué';
  end if;

  -- Essai réel, annulé aussitôt : supprimer TOUS les profils admin doit échouer.
  v_bloque := false;
  begin
    delete from public.profiles where role = 'admin';
  exception when others then
    v_bloque := true;
  end;
  if not v_bloque then
    raise exception 'Utilisateurs : supprimer tous les administrateurs n''a pas été bloqué';
  end if;

  -- Les essais ont bien été annulés : les administrateurs sont toujours là.
  select count(*) into v_nb from public.profiles where role = 'admin';
  if v_nb < 1 then
    raise exception 'Utilisateurs : les essais ont modifié les administrateurs';
  end if;
end
$$;
