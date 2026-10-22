import "server-only";
import { creerClientAdmin } from "@/lib/supabase/admin";

// Hors du fichier "use server" pour ne pas être appelable depuis le navigateur.
export async function unCompteExisteDeja(): Promise<boolean> {
  const admin = creerClientAdmin();
  const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 1 });
  // En cas de doute (erreur), on considère l'inscription comme fermée.
  if (error) return true;
  return data.users.length > 0;
}
