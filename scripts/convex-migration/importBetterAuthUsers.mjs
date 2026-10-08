import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { ConvexHttpClient } from "convex/browser";
import { internal } from "../../convex/_generated/api.js";

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
  // importUserBatch is internal (it can create users with chosen password
  // hashes), so this one-off script needs a deploy key for the target.
  const deployKey = args.get("deploy-key") || process.env.CONVEX_DEPLOY_KEY;
  if (!deployKey) {
    throw new Error("CONVEX_DEPLOY_KEY (or --deploy-key) is required: importUserBatch is an internal function.");
  }
  return { inputDir, convexUrl, deployKey };
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

export async function importBetterAuthUsers({ inputDir, convexUrl, deployKey }) {
  const [users, accounts] = await Promise.all([
    readJson(join(inputDir, "users.json")),
    readJson(join(inputDir, "accounts.json")),
  ]);
  const client = new ConvexHttpClient(convexUrl);
  client.setAdminAuth(deployKey);
  return client.mutation(internal.auth.importUserBatch, { users, accounts });
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
