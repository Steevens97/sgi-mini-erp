import Link from "next/link";
import { notFound } from "next/navigation";
import { exigerAdmin } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { CONSTATS_RESOLUTION, LIBELLES_STATUT_RELANCE } from "@/lib/relances";
import { FormulaireAction, champ } from "../../../commercial/composants";
import { resoudreRelance } from "../actions";

// Fiche d'une relance : demande figée, tentatives, acceptation, livraison, historique, résolution (administrateur).
type Evenement = { action: string; le: string; motif?: string; erreur?: string; type?: string; evenement_id?: string; numero?: number;
                   tentative?: number; constat?: string; auteur_nom?: string; anomalie?: boolean; detail?: string };
const heure = (t: string | null | undefined) => t ? new Date(t).toLocaleString("fr-FR", { timeZone: "America/Martinique" }) : "—";
const LIBELLES_EVENEMENT: Record<string, string> = {
  reservation: "Réservation (aucun envoi)", tentative: "Tentative d'envoi (appel au fournisseur)", acceptation: "Acceptée par le fournisseur",
  temporaire: "Réponse temporaire (nouvelle tentative plus tard)", refus: "Refusée par le fournisseur", incertain: "Réponse incertaine",
  a_verifier: "À vérifier", abandon: "Abandonnée (aucun email)", evenement: "Événement de livraison", resolution: "Résolution par l'administrateur",
};

export default async function PageRelance({ params, searchParams }: {
  params: Promise<{ id: string }>; searchParams: Promise<{ confirmation?: string }>;
}) {
  await exigerAdmin();
  const { id } = await params;
  const confirmation = (await searchParams).confirmation === "resolution";
  const { data: r } = await creerClientAdmin().from("relances")
    .select("id, rang, statut, essai, destinataire, objet, message, created_at, jour_relance, tentatives, premiere_tentative_le, derniere_tentative_le, limite_reprise, compte_fournisseur, accepte_le, date_envoi, fournisseur_id, livre_le, rebond_le, rebond_motif, erreur, resolu_par_nom, resolu_le, motif_resolution, historique, requete_fournisseur, factures(id, numero)")
    .eq("id", id).maybeSingle();
  if (!r) notFound();
  const facture = r.factures as unknown as { id: string; numero: string } | null;
  const bloquante = (["reservee", "en_cours", "a_verifier", "refusee"].includes(r.statut) && !r.resolu_le)
    || (r.statut === "rejetee" && (!r.resolu_le || r.resolu_le < (r.rebond_le ?? "")));
  const constats = CONSTATS_RESOLUTION.filter((c) => (c.pour as readonly string[]).includes(r.statut));
  const requete = r.requete_fournisseur as { from: string; reply_to: string | null; piece_jointe: { nom: string } };
  return (
    <div className="space-y-5">
      <p className="text-sm"><Link href="/finance/relances" className="underline">← Relances</Link></p>
      {confirmation && <p role="status" data-confirmation className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800">
        Résolution enregistrée. Aucun email n&apos;a été renvoyé.</p>}
      <h1 className="text-2xl font-semibold">Relance n° {r.rang} — facture {facture?.numero} {r.essai && <span className="text-amber-800">(ESSAI)</span>}</h1>
      <p className="text-sm">État : <strong data-statut={r.statut}>{LIBELLES_STATUT_RELANCE[r.statut] ?? r.statut}</strong>
        {bloquante && <span className="ml-2 text-amber-800">— bloque toute nouvelle relance de cette facture jusqu&apos;à sa résolution</span>}</p>
      <dl className="grid gap-x-4 gap-y-1 rounded-lg border border-slate-200 bg-white p-4 text-sm sm:grid-cols-2">
        <dt className="text-slate-500">Réservée le (aucun envoi)</dt><dd>{heure(r.created_at)}</dd>
        <dt className="text-slate-500">Tentatives</dt><dd>{r.tentatives} (première : {heure(r.premiere_tentative_le)} ; dernière : {heure(r.derniere_tentative_le)})</dd>
        <dt className="text-slate-500">Limite de reprise (jamais renouvelée)</dt><dd>{heure(r.limite_reprise)}</dd>
        <dt className="text-slate-500">Compte fournisseur (référence)</dt><dd data-compte>{r.compte_fournisseur ?? "— (jamais tentée)"}</dd>
        <dt className="text-slate-500">Acceptée par le fournisseur le</dt><dd data-date-envoi>{heure(r.date_envoi)}</dd>
        <dt className="text-slate-500">Livraison</dt><dd>{r.rebond_le ? `Rejetée le ${heure(r.rebond_le)} (${r.rebond_motif ?? "rejet définitif"})` : r.livre_le ? `Livrée le ${heure(r.livre_le)}` : "Non suivie ou inconnue"}</dd>
        <dt className="text-slate-500">Dernière erreur</dt><dd>{r.erreur ?? "—"}</dd>
        <dt className="text-slate-500">De</dt><dd>{requete.from}{requete.reply_to ? ` (réponse : ${requete.reply_to})` : ""}</dd>
        <dt className="text-slate-500">À</dt><dd>{r.destinataire}</dd>
        <dt className="text-slate-500">Objet</dt><dd>{r.objet}</dd>
        <dt className="text-slate-500">Pièce jointe</dt><dd>{requete.piece_jointe.nom} (PDF archivé, empreinte contrôlée)</dd>
        {r.resolu_le && (<><dt className="text-slate-500">Résolution</dt><dd>{heure(r.resolu_le)} par {r.resolu_par_nom} : {r.motif_resolution}</dd></>)}
      </dl>
      <pre className="whitespace-pre-wrap rounded-lg border border-slate-200 bg-white p-3 text-xs">{r.message}</pre>

      {bloquante && (
        <FormulaireAction action={resoudreRelance} caches={{ relance_id: r.id }} libelle="Enregistrer la résolution"
          confirmation="Enregistrer ce constat ? Aucun email ne sera renvoyé." className="space-y-3 rounded-lg border border-slate-200 bg-white p-4">
          <p className="text-sm font-medium">Résoudre (constat seulement : aucun email n&apos;est renvoyé)</p>
          <label className="block text-sm">Constat
            <select name="constat" required className={champ}>
              {constats.map((c) => <option key={c.valeur} value={c.valeur}>{c.libelle}</option>)}
            </select></label>
          <label className="block text-sm">Motif (obligatoire)
            <input name="motif" required minLength={5} className={champ} /></label>
          {constats.some((c) => c.valeur === "email_accepte") && (<>
            <label className="block text-sm">Date et heure de l&apos;envoi constaté (heure de Martinique, si « email accepté »)
              <input type="datetime-local" name="date_envoi" className={champ} /></label>
            <label className="block text-sm">Identifiant de l&apos;email chez le fournisseur (facultatif)
              <input name="fournisseur_id" className={champ} /></label>
          </>)}
        </FormulaireAction>
      )}

      <section>
        <h2 className="mb-2 text-lg font-semibold">Historique</h2>
        <ol className="space-y-1 text-sm" data-historique>
          {((r.historique ?? []) as Evenement[]).map((e, i) => (
            <li key={i} className="rounded border border-slate-100 bg-white px-2 py-1">
              {heure(e.le)} — {LIBELLES_EVENEMENT[e.action] ?? e.action}
              {e.type ? ` : ${e.type}` : ""}{e.anomalie ? " (anomalie : consigné sans effet)" : ""}
              {e.erreur ? ` — ${e.erreur}` : ""}{e.motif ? ` — ${e.motif}` : ""}{e.auteur_nom ? ` (${e.auteur_nom})` : ""}
            </li>))}
        </ol>
      </section>
    </div>
  );
}
