import Link from "next/link";
import { notFound } from "next/navigation";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { LIBELLES_STATUT_DEVIS, LIBELLES_STATUT_PROSPECT, dateFr, euros } from "@/lib/format";
import { changerStatutProspect, creerDevis, modifierProspect } from "../../actions";
import { FormulaireAction, FormulaireProspect } from "../../composants";

export default async function PageProspect({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const moi = await lireUtilisateurCourant();
  const commercial = moi.role === "admin" || moi.role === "manager";
  const supabase = await creerClientServeur();

  const { data: prospect } = commercial
    ? await supabase.from("prospects")
        .select("id, nom, societe, email, telephone, source, statut, essai, adresse, code_postal, ville, pays, client_id")
        .eq("id", id).maybeSingle()
    : await supabase.from("commercial_prospects").select("id, nom, societe, source, statut, essai").eq("id", id).maybeSingle();
  if (!prospect) notFound();
  const { data: devis } = await supabase.from(commercial ? "devis" : "commercial_devis")
    .select("id, numero, statut, total_ttc, essai, avenant_du_devis_id, remplace_devis_id, created_at")
    .eq("prospect_id", id).order("created_at");
  const p = prospect as Record<string, string | boolean | null>;

  return (
    <div className="space-y-6">
      <div>
        <Link href="/commercial" className="text-sm text-slate-600 underline">← Commercial</Link>
        <h1 className="mt-2 text-2xl font-semibold">
          {String(p.societe || p.nom)} {p.essai ? <span className="rounded bg-red-100 px-2 text-base text-red-800">ESSAI</span> : null}
        </h1>
        <p className="text-slate-600">Statut : {LIBELLES_STATUT_PROSPECT[String(p.statut)] ?? String(p.statut)}
          {p.client_id ? " — client créé" : ""}</p>
      </div>

      {commercial && !p.essai ? (
        <>
          <FormulaireProspect action={modifierProspect} idProspect={id} libelle="Enregistrer"
            v={{ nom: String(p.nom ?? ""), societe: String(p.societe ?? ""), email: String(p.email ?? ""),
              telephone: String(p.telephone ?? ""), source: String(p.source ?? ""), adresse: String(p.adresse ?? ""),
              code_postal: String(p.code_postal ?? ""), ville: String(p.ville ?? ""), pays: String(p.pays ?? "") }} />
          <div className="flex flex-wrap gap-2">
            <FormulaireAction action={changerStatutProspect} caches={{ prospect_id: id, statut: "perdu" }} libelle="Marquer perdu" />
            <FormulaireAction action={changerStatutProspect} caches={{ prospect_id: id, statut: "contacte" }} libelle="Repasser à « contacté »" />
          </div>
          <p className="text-sm text-slate-500">« Devis envoyé » et « Gagné » découlent des devis (déclaration d&apos;envoi, acceptation).</p>
        </>
      ) : (
        <p className="text-sm text-slate-500">{commercial ? "Prospect d'essai : lecture seule." : "Consultation : nom, société, source et statut."}</p>
      )}

      <section>
        <div className="mb-2 flex items-center justify-between">
          <h2 className="text-lg font-semibold">Devis</h2>
          {commercial && !p.essai && <FormulaireAction action={creerDevis} caches={{ prospect_id: id }} libelle="Nouveau devis" principal />}
        </div>
        <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200 bg-white">
          {(devis ?? []).map((d) => (
            <li key={d.id} className="flex justify-between px-4 py-2 text-sm">
              <Link href={`/commercial/devis/${d.id}`} className="font-medium hover:underline">
                {d.numero ?? "Brouillon"}{d.avenant_du_devis_id ? " (avenant)" : d.remplace_devis_id ? " (nouvelle version)" : ""}
                <span className="font-normal text-slate-500"> — {dateFr(d.created_at)}</span>
              </Link>
              <span>{euros(d.total_ttc)} TTC — {LIBELLES_STATUT_DEVIS[d.statut] ?? d.statut}</span>
            </li>
          ))}
          {(devis ?? []).length === 0 && <li className="px-4 py-3 text-sm text-slate-500">Aucun devis.</li>}
        </ul>
      </section>
    </div>
  );
}
