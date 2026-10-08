import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";
import { transformAccountPlaneExport } from "./transformAccountPlaneExport.mjs";

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
    throw new Error("Usage: node scripts/convex-migration/prepareAccountPlaneImport.mjs --input <supabase-json> --output <dir>");
  }
  return { inputPath, outputDir };
}

function extractExportRows(raw) {
  if (!raw || typeof raw !== "object") {
    throw new Error("Supabase export JSON must be an object.");
  }
  if ("profiles" in raw) return raw;

  const rows = raw.rows;
  if (!Array.isArray(rows) || rows.length !== 1 || !rows[0] || typeof rows[0] !== "object") {
    throw new Error("Expected Supabase CLI JSON with exactly one result row.");
  }
  const exportRows = rows[0].account_plane_export;
  if (!exportRows || typeof exportRows !== "object") {
    throw new Error("Expected result row to contain account_plane_export.");
  }
  return exportRows;
}

export async function prepareAccountPlaneImportFiles({ inputPath, outputDir }) {
  const raw = JSON.parse(await readFile(inputPath, "utf8"));
  const transformed = transformAccountPlaneExport(extractExportRows(raw));
  const tables = {};

  await mkdir(outputDir, { recursive: true });
  for (const [tableName, documents] of Object.entries(transformed)) {
    if (!Array.isArray(documents)) continue;
    tables[tableName] = documents.length;
    await writeFile(join(outputDir, `${tableName}.json`), `${JSON.stringify(documents, null, 2)}\n`);
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    sourceFile: basename(inputPath),
    tables,
  };
  await writeFile(join(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  prepareAccountPlaneImportFiles(parseArgs(process.argv.slice(2)))
    .then((manifest) => {
      console.log(JSON.stringify({ tables: manifest.tables }, null, 2));
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
