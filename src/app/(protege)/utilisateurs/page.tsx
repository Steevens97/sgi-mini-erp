import { exigerAdmin } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { INDICATEUR_CHANGEMENT_MDP, estCompteProtege } from "@/lib/utilisateurs";
import type { Role } from "@/lib/navigation";
import {
  CelluleActions,
  FormulaireNouvelleFiche,
  FormulaireRattachement,
  type CompteAffiche,
  type FicheLibre,
} from "./composants";

export default async function PageUtilisateurs() {
  const moi = await exigerAdmin();
  const supabase = await creerClientServeur();

  const [{ data: fiches }, { data: profils }, comptesAuth] = await Promise.all([
    supabase
      .from("collaborateurs")
      .select("id, nom, prenom, email, poste")
      .order("nom"),
    supabase.from("profiles").select("id, email, nom, role, collaborateur_id"),
    creerClientAdmin().auth.admin.listUsers({ page: 1, perPage: 1000 }),
  ]);

  const infosAuth = new Map(
    (comptesAuth.data?.users ?? []).map((u) => [
      u.id,
      {
        derniereConnexion: u.last_sign_in_at ?? null,
        mdpProvisoire: u.app_metadata?.[INDICATEUR_CHANGEMENT_MDP] === true,
      },
    ]),
  );

  const versCompte = (p: NonNullable<typeof profils>[number]): CompteAffiche => ({
    id: p.id,
    email: p.email ?? "",
    nom: p.nom,
    role: p.role as Role,
    estMoi: p.id === moi.id,
    protege: estCompteProtege(p.email),
    mdpProvisoire: infosAuth.get(p.id)?.mdpProvisoire ?? false,
    derniereConnexion: infosAuth.get(p.id)?.derniereConnexion ?? null,
  });

  const listeFiches = fiches ?? [];
  const listeProfils = profils ?? [];
  const fichesLibres: FicheLibre[] = listeFiches
    .filter((f) => !listeProfils.some((p) => p.collaborateur_id === f.id))
    .map((f) => ({ id: f.id, libelle: [f.prenom, f.nom].filter(Boolean).join(" ") }));
  const comptesSansFiche = listeProfils.filter((p) => !p.collaborateur_id).map(versCompte);

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-semibold">Utilisateurs</h1>
        <p className="mt-1 text-slate-600">Accès des collaborateurs à l&apos;application.</p>
      </div>

      <section>
        <h2 className="mb-3 text-lg font-semibold">Collaborateurs et état de leur accès</h2>
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 bg-slate-50 text-slate-600">
              <tr>
                <th className="px-4 py-3 font-medium">Collaborateur</th>
                <th className="px-4 py-3 font-medium">Email de la fiche</th>
                <th className="px-4 py-3 font-medium">Accès</th>
                <th className="px-4 py-3 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {listeFiches.map((fiche) => {
                const profil = listeProfils.find((p) => p.collaborateur_id === fiche.id);
                const compte = profil ? versCompte(profil) : null;
                return (
                  <tr key={fiche.id} className="border-b border-slate-100 align-top last:border-0">
                    <td className="px-4 py-3">
                      <div className="font-medium">
                        {[fiche.prenom, fiche.nom].filter(Boolean).join(" ")}
                      </div>
                      <div className="text-slate-500">{fiche.poste ?? "—"}</div>
                    </td>
                    <td className="px-4 py-3 text-slate-700">{fiche.email ?? "—"}</td>
                    <td className="px-4 py-3">
                      <EtatAcces compte={compte} emailFiche={fiche.email} />
                    </td>
                    <td className="px-4 py-3">
                      <CelluleActions
                        collaborateurId={fiche.id}
                        compte={compte}
                        ficheSansEmail={!fiche.email}
                      />
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-lg font-semibold">Comptes sans fiche collaborateur</h2>
        <p className="mb-3 text-sm text-slate-600">
          Un compte non rattaché ne voit aucune donnée personnelle. Rattachez-le à une fiche libre.
        </p>
        {comptesSansFiche.length === 0 ? (
          <p className="text-sm text-slate-500">Tous les comptes sont rattachés.</p>
        ) : (
          <ul className="space-y-3">
            {comptesSansFiche.map((compte) => (
              <li key={compte.id} className="rounded-lg border border-slate-200 bg-white p-4">
                <div className="mb-2 text-sm">
                  <span className="font-medium">{compte.email}</span>{" "}
                  <span className="text-slate-500">
                    ({compte.role}
                    {compte.estMoi ? ", vous" : ""})
                  </span>
                </div>
                <FormulaireRattachement compteId={compte.id} fichesLibres={fichesLibres} />
                {!compte.estMoi && (
                  <div className="mt-3">
                    <CelluleActions collaborateurId={null} compte={compte} />
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="mb-1 text-lg font-semibold">Nouvelle fiche collaborateur</h2>
        <p className="mb-3 text-sm text-slate-600">
          Pour créer votre propre fiche, cochez « Rattacher cette fiche à mon compte ».
        </p>
        <FormulaireNouvelleFiche monCompteDejaRattache={!!moi.collaborateurId} />
      </section>
    </div>
  );
}

function EtatAcces({
  compte,
  emailFiche,
}: {
  compte: CompteAffiche | null;
  emailFiche: string | null;
}) {
  if (!compte) {
    return <span className="rounded bg-slate-100 px-2 py-1 text-slate-600">Aucun accès</span>;
  }
  return (
    <div className="space-y-1">
      <span className="rounded bg-emerald-50 px-2 py-1 text-emerald-800">Accès actif — {compte.role}</span>
      {compte.mdpProvisoire && (
        <div className="text-amber-700">Mot de passe provisoire à remplacer</div>
      )}
      {compte.email && emailFiche && compte.email.toLowerCase() !== emailFiche.toLowerCase() && (
        <div className="text-slate-500">Compte : {compte.email}</div>
      )}
      <div className="text-slate-500">
        {compte.derniereConnexion
          ? `Dernière connexion : ${new Date(compte.derniereConnexion).toLocaleString("fr-FR", { timeZone: "America/Martinique" })}`
          : "Jamais connecté"}
      </div>
    </div>
  );
}
