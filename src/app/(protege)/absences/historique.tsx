import { LIBELLES_EVENEMENT_ABSENCES, LIBELLES_TYPE_ABSENCE, nombreFr, type EvenementAbsences } from "@/lib/absences";
import { dateFr, euros } from "@/lib/format";

const quand = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString("fr-FR", { timeZone: "America/Martinique", dateStyle: "short", timeStyle: "short" }) : "date inconnue";

function detail(e: EvenementAbsences, soldes: boolean): string {
  const morceaux: string[] = [];
  if (soldes) {
    morceaux.push(LIBELLES_TYPE_ABSENCE[e.type ?? ""] ?? "");
    if (e.avant !== null && e.avant !== undefined) morceaux.push(`${nombreFr(e.avant as number)} → ${nombreFr(e.apres as number)} j`);
    else morceaux.push(`${nombreFr(e.apres as number)} j`);
    if (e.jours) morceaux.push(`${nombreFr(e.jours)} j prélevé(s)`);
  } else {
    const avant = e.avant as Record<string, unknown> | undefined;
    if (e.action === "modification" && avant) {
      morceaux.push(`avant : ${euros(avant.montant as number)}, ${String(avant.objet ?? "")}${avant.justificatif_url ? ", ancien justificatif conservé" : ""}`);
    }
    if (e.action === "remboursement_declare") morceaux.push(`le ${dateFr(e.rembourse_le ?? null)}${e.reference ? `, réf. ${e.reference}` : ""}`);
    if ((e.action === "remboursement_corrige" || e.action === "remboursement_annule") && avant) {
      morceaux.push(`valeurs précédentes : ${dateFr((avant.rembourse_le as string) ?? null)}${avant.reference ? `, réf. ${avant.reference}` : ""}`);
    }
  }
  return morceaux.filter(Boolean).join(" — ");
}

// Historique enregistré par la base (lecture seule, ajout seul).
export function HistoriqueAbsences({ evenements, soldes = false, titre = "Historique" }: {
  evenements: EvenementAbsences[] | null; soldes?: boolean; titre?: string;
}) {
  if (!evenements?.length) return null;
  return (
    <details className="text-xs text-slate-600">
      <summary className="cursor-pointer">{titre} ({evenements.length})</summary>
      <ol className="mt-1 list-decimal space-y-1 pl-4">
        {evenements.map((e, i) => (
          <li key={i}>
            <strong>{LIBELLES_EVENEMENT_ABSENCES[e.action] ?? e.action}</strong> — {quand(e.le)} — {e.auteur_nom ?? (e.action === "initial" ? "base" : "auteur inconnu")}
            {detail(e, soldes) ? ` — ${detail(e, soldes)}` : ""}
            {e.motif ? ` — motif : ${e.motif}` : ""}
          </li>
        ))}
      </ol>
    </details>
  );
}
