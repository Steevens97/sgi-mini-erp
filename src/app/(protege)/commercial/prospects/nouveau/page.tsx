import { exigerCommercial } from "@/lib/session";
import { creerProspect } from "../../actions";
import { FormulaireProspect } from "../../composants";

export default async function PageNouveauProspect() {
  await exigerCommercial();
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Nouveau prospect</h1>
      <FormulaireProspect action={creerProspect} v={{ pays: "MQ" }} libelle="Créer le prospect" />
    </div>
  );
}
