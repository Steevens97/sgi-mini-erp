import Link from "next/link";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { CALENDRIER_RELANCES, LIBELLES_STATUT_RELANCE, LIMITES_RELANCES, blocagesRelancesReelles, construireDemande,
         type FactureARelancer } from "@/lib/relances";
import { dateFr, euros } from "@/lib/format";

// Écran des relances (administrateur). Lecture avec la clé secrète après exigerAdmin. La SIMULATION n'écrit rien et
// n'envoie rien : elle calcule l'aperçu de la base (fonction en lecture seule) et construit les messages à l'écran,
// sans réservation ni appel au fournisseur (ce fichier n'importe pas le module d'envoi).
type Ligne = FactureARelancer & { facture_id: string; client_nom: string; client_email: string | null; statut: string;
  rang: 1 | 2 | 3 | null; blocage: string | null; pdf_disponible: boolean; email_client: boolean; retard_jours: number };
type Relance = { id: string; rang: number; statut: string; essai: boolean; destinataire: string; objet: string; created_at: string;
  tentatives: number; date_envoi: string | null; livre_le: string | null; rebond_le: string | null; erreur: string | null;
  factures: { numero: string } | null };

const heure = (t: string | null) => t ? new Date(t).toLocaleString("fr-FR", { timeZone: "America/Martinique" }) : "—";
const ZERO = "00000000-0000-0000-0000-000000000000";

export default async function PageRelances({ searchParams }: { searchParams: Promise<{ simulation?: string }> }) {
  await exigerAdmin();
  const simulation = (await searchParams).simulation === "1";
  const admin = creerClientAdmin();
  const [{ data: apercu }, { data: relances }] = await Promise.all([
    admin.rpc("relances_apercu"),
    admin.from("relances").select("id, rang, statut, essai, destinataire, objet, created_at, tentatives, date_envoi, livre_le, rebond_le, erreur, factures(numero)")
      .order("created_at", { ascending: false }).limit(200),
  ]);
  const lignes = (apercu ?? []) as Ligne[];
  const liste = (relances ?? []) as unknown as Relance[];
  const actives = process.env.RELANCES_ACTIVES === "1";
  const adresseEssai = (process.env.RELANCES_ADRESSE_ESSAI ?? "").trim().toLowerCase() || null;
  // État de la configuration : présence seulement, jamais les valeurs.
  const etat = [
    ["Clé du fournisseur", !!process.env.RESEND_API_KEY],
    ["Secret partagé avec la tâche planifiée", (process.env.RELANCES_SECRET_CRON ?? "").length >= 32],
    ["Secret de signature des événements de livraison", (process.env.RESEND_WEBHOOK_SECRET ?? "").startsWith("whsec_")],
    ["Adresse de test confirmée (essais)", !!adresseEssai],
  ] as const;
  const bloquesReels = blocagesRelancesReelles();
  const sansPdf = lignes.filter((l) => !l.pdf_disponible);
  const sansEmail = lignes.filter((l) => l.pdf_disponible && !l.email_client);
  const dues = lignes.filter((l) => l.rang);
  return (
    <div className="space-y-6">
      <p className="text-sm"><Link href="/finance" className="underline">← Finance</Link></p>
      <h1 className="text-2xl font-semibold">Relances des factures</h1>
      <div role="alert" data-etat-relances={actives ? "actives" : "inactives"}
        className={`rounded-md border p-3 text-sm ${actives ? "border-emerald-300 bg-emerald-50 text-emerald-900" : "border-amber-300 bg-amber-50 text-amber-900"}`}>
        <p className="font-medium">{actives ? "Relances automatiques activées." : "Relances automatiques NON activées : aucun email n'est envoyé."}</p>
        <ul className="mt-1 list-disc pl-5">{etat.map(([libelle, present]) => <li key={libelle}>{libelle} : {present ? "renseigné" : "absent"}</li>)}</ul>
        {bloquesReels.length > 0 && (<>
          <p className="mt-2 font-medium">Relances réelles bloquées :</p>
          <ul className="list-disc pl-5" data-blocages-reels>{bloquesReels.map((b) => <li key={b}>{b}</li>)}</ul>
        </>)}
      </div>
      <div className="rounded-md border border-slate-200 bg-slate-50 p-3 text-sm text-slate-700">
        <p>{CALENDRIER_RELANCES}</p>
        <ul className="mt-1 list-disc pl-5">{LIMITES_RELANCES.map((l) => <li key={l}>{l}</li>)}</ul>
      </div>

      <form method="get">
        <input type="hidden" name="simulation" value="1" />
        <button type="submit" className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50">
          Simuler les relances du jour (aucun envoi)</button>
      </form>
      {simulation && (
        <section className="space-y-2" data-simulation>
          <p role="status" className="rounded-md border border-sky-200 bg-sky-50 p-3 text-sm text-sky-900">
            Simulation : rien n&apos;a été réservé ni envoyé. {dues.length} relance(s) seraient dues maintenant.</p>
          {dues.map((l) => {
            const c = construireDemande({ relanceId: ZERO, rang: l.rang!, facture: l, emailClient: l.client_email, adresseEssai });
            return (
              <div key={l.facture_id} data-simulation-facture={l.numero} className="rounded-lg border border-slate-200 bg-white p-3 text-sm">
                <p className="font-medium">{l.numero} — relance n° {l.rang} — {l.client_nom}</p>
                {"blocage" in c
                  ? <p className="text-amber-800" data-simulation-blocage>Ne partirait pas : {c.blocage}</p>
                  : (<>
                    <p>À : {c.demande.to} — De : {c.demande.from}{c.demande.reply_to ? ` — Réponse : ${c.demande.reply_to}` : ""}</p>
                    <p>Objet : <span data-simulation-objet>{c.demande.subject}</span> — pièce jointe : {c.demande.piece_jointe.nom}</p>
                    <pre className="mt-1 whitespace-pre-wrap rounded bg-slate-50 p-2 text-xs">{c.demande.text}</pre>
                  </>)}
              </div>
            );
          })}
        </section>
      )}

      <section>
        <h2 className="mb-2 text-lg font-semibold">Factures émises ou envoyées, impayées et échues</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
          <thead className="bg-slate-50 text-left"><tr><th className="p-2">Facture</th><th className="p-2">Client</th>
            <th className="p-2">Échéance</th><th className="p-2 text-right">Total TTC</th><th className="p-2">Situation</th></tr></thead>
          <tbody>
            {lignes.map((l) => (
              <tr key={l.facture_id} data-facture={l.numero} className="border-t border-slate-100">
                <td className="p-2">{l.numero}{l.essai && <span className="ml-2 rounded bg-amber-100 px-1 text-xs text-amber-900">ESSAI</span>}</td>
                <td className="p-2">{l.client_nom}</td>
                <td className="p-2">{dateFr(l.date_echeance)} (J+{l.retard_jours})</td>
                <td className="p-2 text-right">{euros(l.total_ttc)}</td>
                <td className="p-2" data-situation>{l.rang ? `Relance n° ${l.rang} due` : l.blocage}</td>
              </tr>))}
            {!lignes.length && <tr><td colSpan={5} className="p-3 text-slate-500">Aucune facture échue impayée.</td></tr>}
          </tbody>
        </table>
      </section>

      <section className="grid gap-4 sm:grid-cols-2">
        <div className="rounded-lg border border-amber-200 bg-white p-3 text-sm" data-sans-pdf>
          <h2 className="font-semibold">Factures sans PDF archivé (jamais relancées)</h2>
          <ul className="mt-1 list-disc pl-5">{sansPdf.map((l) => <li key={l.facture_id}>{l.numero} — {l.client_nom}</li>)}</ul>
          {!sansPdf.length && <p className="text-slate-500">Aucune.</p>}
        </div>
        <div className="rounded-lg border border-amber-200 bg-white p-3 text-sm" data-sans-email>
          <h2 className="font-semibold">Clients sans email (factures jamais relancées)</h2>
          <ul className="mt-1 list-disc pl-5">{sansEmail.map((l) => <li key={l.facture_id}>{l.numero} — {l.client_nom}</li>)}</ul>
          {!sansEmail.length && <p className="text-slate-500">Aucun.</p>}
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-lg font-semibold">Relances</h2>
        <table className="w-full rounded-lg border border-slate-200 bg-white text-sm">
          <thead className="bg-slate-50 text-left"><tr><th className="p-2">Facture</th><th className="p-2">N°</th><th className="p-2">État</th>
            <th className="p-2">Réservée le</th><th className="p-2">Tentatives</th><th className="p-2">Acceptée le</th><th className="p-2">Livraison</th></tr></thead>
          <tbody>
            {liste.map((r) => (
              <tr key={r.id} data-relance={r.id} className="border-t border-slate-100">
                <td className="p-2"><Link href={`/finance/relances/${r.id}`} className="underline">{r.factures?.numero}</Link>
                  {r.essai && <span className="ml-2 rounded bg-amber-100 px-1 text-xs text-amber-900">ESSAI</span>}</td>
                <td className="p-2">{r.rang}</td>
                <td className="p-2" data-statut={r.statut}>{LIBELLES_STATUT_RELANCE[r.statut] ?? r.statut}</td>
                <td className="p-2">{heure(r.created_at)}</td>
                <td className="p-2">{r.tentatives}</td>
                <td className="p-2">{heure(r.date_envoi)}</td>
                <td className="p-2">{r.rebond_le ? `Rejetée le ${heure(r.rebond_le)}` : r.livre_le ? `Livrée le ${heure(r.livre_le)}` : "—"}</td>
              </tr>))}
            {!liste.length && <tr><td colSpan={7} className="p-3 text-slate-500">Aucune relance.</td></tr>}
          </tbody>
        </table>
      </section>
    </div>
  );
}
