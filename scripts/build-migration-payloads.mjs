import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const migrationsDir = path.join(root, "supabase", "migrations");
const outDir = path.join(root, "mig-payloads");

const files = fs
  .readdirSync(migrationsDir)
  .filter((f) => f.endsWith(".sql") && f >= "20260520120000" && f <= "20260528129999")
  .sort();

fs.mkdirSync(outDir, { recursive: true });

for (const f of files) {
  const query = fs.readFileSync(path.join(migrationsDir, f), "utf8");
  const name = f.replace(/\.sql$/, "");
  const payload = { project_id: "mijuuofcxvqpsepyseyd", name, query };
  fs.writeFileSync(path.join(outDir, `${name}.json`), JSON.stringify(payload), "utf8");
  console.log("wrote", name);
}
