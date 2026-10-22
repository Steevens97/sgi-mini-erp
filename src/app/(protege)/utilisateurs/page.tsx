import { EnConstruction } from "@/components/en-construction";
import { exigerAdmin } from "@/lib/session";

export default async function PageUtilisateurs() {
  await exigerAdmin();
  return (
    <EnConstruction
      titre="Utilisateurs"
      description="Accès des collaborateurs à l'application."
    />
  );
}
