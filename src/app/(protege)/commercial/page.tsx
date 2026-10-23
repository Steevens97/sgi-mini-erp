import Link from "next/link";
import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { champsEmetteurManquants, coordonneesEmetteur } from "@/lib/entreprise";
import { LIBELLES_STATUT_DEVIS, LIBELLES_STATUT_PROSPECT, dateFr, euros } from "@/lib/format";

type Prospect = { id: string; nom: string; societe: string | null; statut: string; essai: boolean };
type Devis = { id: string; numero: string | null; statut: string; total_ttc: number; prospect_id: string; essai: boolean;
  avenant_du_devis_id: string | null; created_at: string };

export default async function PageCommercial() {
  const moi = await lireUtilisateurCourant();
  const commercial = moi.role === "admin" || moi.role === "manager";
  const supabase = await creerClientServeur();
  // Admin et manager : tables (règles RLS). Collaborateur : vues de consultation uniquement.
  const [{ data: prospects }, { data: devis }] = await Promise.all([
    supabase.from(commercial ? "prospects" : "commercial_prospects").select("id, nom, societe, statut, essai").order("created_at", { ascending: false }),
    supabase.from(commercial ? "devis" : "commercial_devis")
      .select("id, numero, statut, total_ttc, prospect_id, essai, avenant_du_devis_id, created_at").order("created_at", { ascending: false }),
  ]);
  const listeP = (prospects ?? []) as Prospect[];
  const nomProspect = new Map(listeP.map((p) => [p.id, p.societe || p.nom]));
  const manquants = champsEmetteurManquants(coordonneesEmetteur());

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Commercial</h1>
          <p className="mt-1 text-slate-600">Prospects et devis{commercial ? "" : " (consultation)"}.</p>
        </div>
        {commercial && <Link href="/commercial/prospects/nouveau" className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white">Nouveau prospect</Link>}
      </div>

      {commercial && manquants.length > 0 && (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <strong>Émission des devis bloquée</strong> : coordonnées de SG Ingénierie à compléter ({manquants.length} champ(s) :{" "}
          {manquants.join(", ")}). Les brouillons restent possibles.
        </div>
      )}

      <section>
        <h2 className="mb-2 text-lg font-semibold">Prospects</h2>
        <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200 bg-white">
          {listeP.map((p) => (
            <li key={p.id} className="flex items-center justify-between px-4 py-2 text-sm">
              <Link href={`/commercial/prospects/${p.id}`} className="font-medium underline-offset-2 hover:underline">
                {p.societe || p.nom}{p.societe ? <span className="font-normal text-slate-500"> — {p.nom}</span> : null}
              </Link>
              <span className="flex gap-2">
                {p.essai && <span className="rounded bg-red-100 px-2 text-red-800">ESSAI</span>}
                <span className="rounded bg-slate-100 px-2">{LIBELLES_STATUT_PROSPECT[p.statut] ?? p.statut}</span>
              </span>
            </li>
          ))}
          {listeP.length === 0 && <li className="px-4 py-3 text-sm text-slate-500">Aucun prospect.</li>}
        </ul>
      </section>

      <section>
        <h2 className="mb-2 text-lg font-semibold">Devis</h2>
        <ul className="divide-y divide-slate-100 rounded-lg border border-slate-200 bg-white">
          {((devis ?? []) as Devis[]).map((d) => (
            <li key={d.id} className="flex items-center justify-between px-4 py-2 text-sm">
              <Link href={`/commercial/devis/${d.id}`} className="font-medium hover:underline">
                {d.numero ?? "Brouillon"}{d.avenant_du_devis_id ? " (avenant)" : ""}
                <span className="font-normal text-slate-500"> — {nomProspect.get(d.prospect_id) ?? "?"} — {dateFr(d.created_at)}</span>
              </Link>
              <span className="flex gap-2">
                {d.essai && <span className="rounded bg-red-100 px-2 text-red-800">ESSAI</span>}
                <span>{euros(d.total_ttc)} TTC</span>
                <span className="rounded bg-slate-100 px-2">{LIBELLES_STATUT_DEVIS[d.statut] ?? d.statut}</span>
              </span>
            </li>
          ))}
          {(devis ?? []).length === 0 && <li className="px-4 py-3 text-sm text-slate-500">Aucun devis.</li>}
        </ul>
      </section>
    </div>
  );
}
