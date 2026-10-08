import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { prepareAccountPlaneImportFiles } from "./prepareAccountPlaneImport.mjs";

test("prepares Convex import JSON files and manifest from Supabase CLI output", async () => {
  const root = await mkdtemp(join(tmpdir(), "glasstunnel-account-plane-"));
  try {
    const inputPath = join(root, "supabase-export.json");
    const outputDir = join(root, "convex-import");
    await writeFile(
      inputPath,
      JSON.stringify({
        rows: [
          {
            account_plane_export: {
              profiles: [
                {
                  user_id: "user-1",
                  email: "person@example.com",
                  display_name: null,
                  avatar_url: null,
                  created_at: "2026-01-01T00:00:00.000Z",
                  updated_at: "2026-01-01T00:01:00.000Z",
                },
              ],
              devices: [],
              device_pairings: [],
              push_subscriptions: [],
              host_link_codes: [],
              device_approval_requests: [],
            },
          },
        ],
      }),
    );

    const manifest = await prepareAccountPlaneImportFiles({ inputPath, outputDir });
    assert.equal(manifest.tables.accountProfiles, 1);
    assert.equal(manifest.tables.accountDevices, 0);

    const profiles = JSON.parse(await readFile(join(outputDir, "accountProfiles.json"), "utf8"));
    const manifestFile = JSON.parse(await readFile(join(outputDir, "manifest.json"), "utf8"));
    assert.equal(profiles[0]?.legacyUserId, "user-1");
    assert.deepEqual(manifestFile.tables, manifest.tables);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
