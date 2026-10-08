import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";
import { transformSupabaseAuthExport } from "./transformSupabaseAuthExport.mjs";

function parseArgs(argv) {
  const args = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[index + 1];
    if (key?.startsWith("--") && value && !value.startsWith("--")) {
      args.set(key.slice(2), value);
      index += 1;
    }
  }
  const inputPath = args.get("input");
  const outputDir = args.get("output");
  if (!inputPath || !outputDir) {
    throw new Error("Usage: node scripts/convex-migration/prepareBetterAuthImport.mjs --input <supabase-auth-json> --output <dir>");
  }
  return { inputPath, outputDir };
}

function extractAuthExport(raw) {
  if (!raw || typeof raw !== "object") {
    throw new Error("Supabase auth export JSON must be an object.");
  }
  if ("users" in raw) return raw;
  const rows = raw.rows;
  if (!Array.isArray(rows) || rows.length !== 1 || !rows[0] || typeof rows[0] !== "object") {
    throw new Error("Expected Supabase CLI JSON with exactly one result row.");
  }
  const exportRows = rows[0].auth_export;
  if (!exportRows || typeof exportRows !== "object") {
    throw new Error("Expected result row to contain auth_export.");
  }
  return exportRows;
}

export async function prepareBetterAuthImportFiles({ inputPath, outputDir }) {
  const raw = JSON.parse(await readFile(inputPath, "utf8"));
  const transformed = transformSupabaseAuthExport(extractAuthExport(raw));
  await mkdir(outputDir, { recursive: true });
  await writeFile(join(outputDir, "users.json"), `${JSON.stringify(transformed.users, null, 2)}\n`);
  await writeFile(join(outputDir, "accounts.json"), `${JSON.stringify(transformed.accounts, null, 2)}\n`);

  const manifest = {
    generatedAt: new Date().toISOString(),
    sourceFile: basename(inputPath),
    users: transformed.users.length,
    accounts: transformed.accounts.length,
    providers: [...new Set(transformed.accounts.map((account) => account.providerId))].sort(),
  };
  await writeFile(join(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  prepareBetterAuthImportFiles(parseArgs(process.argv.slice(2)))
    .then((manifest) => {
      console.log(JSON.stringify(manifest, null, 2));
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
