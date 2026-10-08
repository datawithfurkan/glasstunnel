import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { ConvexHttpClient } from "convex/browser";
import { api } from "../../convex/_generated/api.js";

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
  const inputDir = args.get("input");
  const convexUrl = args.get("convex-url") || process.env.CONVEX_URL || process.env.VITE_CONVEX_URL;
  if (!inputDir || !convexUrl) {
    throw new Error("Usage: node scripts/convex-migration/importBetterAuthUsers.mjs --input <better-auth-import-dir> --convex-url <url>");
  }
  return { inputDir, convexUrl };
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

export async function importBetterAuthUsers({ inputDir, convexUrl }) {
  const [users, accounts] = await Promise.all([
    readJson(join(inputDir, "users.json")),
    readJson(join(inputDir, "accounts.json")),
  ]);
  const client = new ConvexHttpClient(convexUrl);
  return client.mutation(api.auth.importUserBatch, { users, accounts });
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  importBetterAuthUsers(parseArgs(process.argv.slice(2)))
    .then((result) => {
      console.log(JSON.stringify(result, null, 2));
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
