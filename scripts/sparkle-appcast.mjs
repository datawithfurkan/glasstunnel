#!/usr/bin/env node
// Writes the signed update feed (appcast.xml) that the Mac app's updater reads.
//
// The feed carries one item: this release's notarized DMG, its EdDSA signature,
// and the CHANGELOG section for the version as release notes. sign_update then
// signs the whole feed, because the app requires a signed feed.
//
// Usage: node scripts/sparkle-appcast.mjs VERSION [DMG_PATH] [--out PATH]
// Keys:  the private key is read from the login Keychain account "glasstunnel"
//        (GT_SPARKLE_KEY_ACCOUNT), or from GT_SPARKLE_PRIVATE_KEY_FILE.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_URL = 'https://github.com/datawithfurkan/glasstunnel';
const FEED_URL = 'https://glasstunnel.io/appcast.xml';

/** The CHANGELOG section for `version`, without its heading, or null. */
export function changelogSection(changelog, version) {
  const lines = changelog.split('\n');
  const start = lines.findIndex((line) => line.startsWith(`## ${version} `) || line.trim() === `## ${version}`);
  if (start === -1) return null;
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((line) => line.startsWith('## '));
  const body = (end === -1 ? rest : rest.slice(0, end)).join('\n').trim();
  return body || null;
}

/** The heading text after the version, such as "Sharper screen". */
export function changelogTitle(changelog, version) {
  const line = changelog.split('\n').find((candidate) => candidate.startsWith(`## ${version} `));
  return line?.replace(`## ${version}`, '').replace(/^\s*-\s*/, '').trim() || null;
}

function escapeXml(text) {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function cdata(text) {
  return `<![CDATA[${text.replaceAll(']]>', ']]]]><![CDATA[>')}]]>`;
}

export function buildAppcast({
  version,
  title,
  notesMarkdown,
  downloadUrl,
  length,
  edSignature,
  minimumSystemVersion,
  pubDate,
}) {
  const itemTitle = title ? `Glasstunnel ${version}: ${title}` : `Glasstunnel ${version}`;
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Glasstunnel</title>
    <link>${FEED_URL}</link>
    <description>Glasstunnel for Mac releases.</description>
    <language>en</language>
    <item>
      <title>${escapeXml(itemTitle)}</title>
      <link>https://glasstunnel.io/</link>
      <sparkle:version>${escapeXml(version)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXml(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${escapeXml(minimumSystemVersion)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${REPO_URL}/releases/tag/v${escapeXml(version)}</sparkle:fullReleaseNotesLink>
      <pubDate>${pubDate}</pubDate>
      <description sparkle:format="markdown">${cdata(notesMarkdown)}</description>
      <enclosure url="${escapeXml(downloadUrl)}" length="${length}" type="application/octet-stream" sparkle:edSignature="${escapeXml(edSignature)}" />
    </item>
  </channel>
</rss>
`;
}

function findSignUpdate() {
  const candidates = [
    join(ROOT, 'apps/host-macos/.build/artifacts/sparkle/Sparkle/bin/sign_update'),
    join(ROOT, 'apps/host-macos/.build/glasstunnel-release/arm64/artifacts/sparkle/Sparkle/bin/sign_update'),
  ];
  const found = candidates.find((candidate) => existsSync(candidate));
  if (!found) {
    throw new Error(
      'Sparkle sign_update was not found. Run: swift package resolve --package-path apps/host-macos',
    );
  }
  return found;
}

function signUpdate(args) {
  const keyFile = process.env.GT_SPARKLE_PRIVATE_KEY_FILE;
  const keyArgs = keyFile
    ? ['--ed-key-file', keyFile]
    : ['--account', process.env.GT_SPARKLE_KEY_ACCOUNT || 'glasstunnel'];
  return execFileSync(findSignUpdate(), [...keyArgs, ...args], { encoding: 'utf8' }).trim();
}

function minimumSystemVersion() {
  const plist = readFileSync(join(ROOT, 'apps/host-macos/Metadata/Info.plist'), 'utf8');
  const match = plist.match(/<key>LSMinimumSystemVersion<\/key>\s*<string>([^<]+)<\/string>/);
  if (!match) throw new Error('LSMinimumSystemVersion is missing from apps/host-macos/Metadata/Info.plist');
  return match[1];
}

/** Removes `--name value` from args and returns the value. */
function takeOption(args, name) {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  const value = args[index + 1];
  args.splice(index, 2);
  return value;
}

function main(argv) {
  const args = [...argv];
  const out = resolve(takeOption(args, '--out') ?? join(ROOT, 'dist/appcast.xml'));
  // The update smoke points these at a local feed; releases use the defaults.
  const changelogPath = resolve(takeOption(args, '--changelog') ?? join(ROOT, 'CHANGELOG.md'));
  const downloadUrlOption = takeOption(args, '--download-url');
  const [version, dmgArg] = args;
  if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
    console.error('Usage: node scripts/sparkle-appcast.mjs VERSION [DMG_PATH] [--out PATH]');
    process.exit(2);
  }
  const dmg = resolve(dmgArg ?? join(ROOT, `dist/Glasstunnel-${version}.dmg`));
  if (!existsSync(dmg)) throw new Error(`DMG not found: ${dmg}`);

  const changelog = readFileSync(changelogPath, 'utf8');
  const notesMarkdown = changelogSection(changelog, version);
  if (!notesMarkdown) throw new Error(`CHANGELOG.md has no "## ${version}" section for the release notes.`);

  const edSignature = signUpdate(['-p', dmg]);
  const xml = buildAppcast({
    version,
    title: changelogTitle(changelog, version),
    notesMarkdown,
    downloadUrl: downloadUrlOption ?? `${REPO_URL}/releases/download/v${version}/Glasstunnel-${version}.dmg`,
    length: statSync(dmg).size,
    edSignature,
    minimumSystemVersion: minimumSystemVersion(),
    pubDate: new Date().toUTCString(),
  });
  writeFileSync(out, xml);

  // The app only accepts a signed feed: sign it, then check both signatures.
  signUpdate([out]);
  signUpdate(['--verify', dmg, edSignature]);
  signUpdate(['--verify', out]);
  console.log(`Wrote and verified ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}
