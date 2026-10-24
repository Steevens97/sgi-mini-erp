import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { PARAMETRES_RH } from "@/lib/rh";

export default async function PageRH() {
  const moi = await lireUtilisateurCourant();
  const valideur = moi.role === "admin" || moi.role === "manager";
  const entrees = [
    { chemin: "/rh/temps", titre: "Mes temps", texte: "Saisir, corriger et soumettre ses temps." },
    ...(valideur ? [{ chemin: "/rh/validation", titre: "Validation", texte: "Valider ou renvoyer les temps soumis." }] : []),
    { chemin: "/rh/notes-de-frais", titre: "Notes de frais",
      texte: valideur ? "Déposer ses notes ; décider de celles de son équipe" + (moi.role === "admin" ? " ; remboursements déclarés." : ".") : "Déposer ses notes avec leur justificatif." },
    { chemin: "/rh/projets", titre: "Projets", texte: valideur ? "Projets, statuts, création (admin)." : "Projets ouverts à la saisie." },
    { chemin: "/rh/collaborateurs", titre: "Collaborateurs", texte: moi.role === "admin" ? "Fiches, managers, taux (admin)." : "Fiches visibles avec vos droits." },
  ];
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">RH</h1>
        <p className="mt-1 text-sm text-slate-600">
          Paramètres de gestion de SG Ingénierie : pas de {String(PARAMETRES_RH.pasHeures).replace(".", ",")} h ; saisie sur{" "}
          {PARAMETRES_RH.fenetreJours} jours ; au-delà de {PARAMETRES_RH.seuilDerogationJour} h par jour, dérogation de
          l&apos;administrateur avec motif ; jamais plus de {PARAMETRES_RH.plafondAbsoluJour} h par jour.
        </p>
      </div>
      <ul className="grid gap-3 sm:grid-cols-2">
        {entrees.map((e) => (
          <li key={e.chemin}>
            <Link href={e.chemin} className="block rounded-lg border border-slate-200 bg-white p-4 hover:bg-slate-50">
              <span className="font-medium">{e.titre}</span>
              <span className="mt-1 block text-sm text-slate-600">{e.texte}</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
