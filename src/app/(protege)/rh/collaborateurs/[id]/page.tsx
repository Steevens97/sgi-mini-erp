import Link from "next/link";
import { notFound } from "next/navigation";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique, managersEligibles, nomComplet } from "@/lib/rh";
import { dateFr } from "@/lib/format";
import { FormulaireFiche } from "../formulaire";

export default async function PageFiche({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const moi = await lireUtilisateurCourant();
  const supabase = await creerClientServeur();
  const colonnes = "id, nom, prenom, email, poste, date_entree, manager_id, date_sortie";
  const { data: fiche } = await supabase.from("collaborateurs").select(colonnes).eq("id", id).maybeSingle();
  if (!fiche) notFound();

  if (moi.role !== "admin") {
    const { data: manager } = fiche.manager_id
      ? await supabase.from("collaborateurs").select("nom, prenom").eq("id", fiche.manager_id).maybeSingle()
      : { data: null };
    return (
      <div className="space-y-4">
        <Link href="/rh/collaborateurs" className="text-sm text-slate-600 underline">← Collaborateurs</Link>
        <h1 className="text-2xl font-semibold">{nomComplet(fiche)}</h1>
        <dl className="grid max-w-lg grid-cols-2 gap-2 text-sm">
          <dt className="text-slate-500">Poste</dt><dd>{fiche.poste ?? "—"}</dd>
          <dt className="text-slate-500">Email</dt><dd>{fiche.email ?? "—"}</dd>
          <dt className="text-slate-500">Entrée</dt><dd>{dateFr(fiche.date_entree)}</dd>
          <dt className="text-slate-500">Manager</dt><dd>{nomComplet(manager)}</dd>
          <dt className="text-slate-500">Sortie</dt><dd>{fiche.date_sortie ? dateFr(fiche.date_sortie) : "—"}</dd>
        </dl>
      </div>
    );
  }

  // Écran d'édition ADMIN : seul endroit où le taux est lu (clé secrète, après vérification du rôle admin
  // par lireUtilisateurCourant + contrôle ci-dessus ; l'action d'enregistrement refait exigerAdmin()).
  const admin = creerClientAdmin();
  const { data: complet } = await admin.from("collaborateurs").select(`${colonnes}, taux_horaire`).eq("id", id).single();
  const { data: toutes } = await supabase.from("collaborateurs").select("id, nom, prenom, manager_id, date_sortie").order("nom");
  const managers = managersEligibles(toutes ?? [], id, aujourdhuiMartinique());
  // Garder le manager actuel visible même s'il n'est plus éligible pour un NOUVEAU rattachement.
  if (fiche.manager_id && !managers.some((m) => m.id === fiche.manager_id)) {
    const actuel = (toutes ?? []).find((m) => m.id === fiche.manager_id);
    if (actuel) managers.push(actuel);
  }
  return (
    <div className="space-y-4">
      <Link href="/rh/collaborateurs" className="text-sm text-slate-600 underline">← Collaborateurs</Link>
      <h1 className="text-2xl font-semibold">Modifier la fiche — {nomComplet(fiche)}</h1>
      <FormulaireFiche
        managers={managers.map((m) => ({ id: m.id, libelle: nomComplet(m) }))}
        valeurs={{ ...complet!, taux_horaire: Number(complet!.taux_horaire) }}
      />
    </div>
  );
}
