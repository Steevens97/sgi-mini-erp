import { EnConstruction } from "@/components/en-construction";
import { exigerAdmin } from "@/lib/session";

export default async function PageFinance() {
  await exigerAdmin();
  return <EnConstruction titre="Finance" description="Factures et relances." />;
}
