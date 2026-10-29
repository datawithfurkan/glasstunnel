import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildAppcast, changelogSection, changelogTitle } from './sparkle-appcast.mjs';

const CHANGELOG = `# Changelog

## Unreleased

- Not shipped yet.

## 0.1.12 - Updates in the app

### Updates

- Check for Updates installs the new version and relaunches.

## 0.1.11 - Earlier

- Older notes.
`;

test('changelogSection returns only the requested release', () => {
  const section = changelogSection(CHANGELOG, '0.1.12');
  assert.equal(section, '### Updates\n\n- Check for Updates installs the new version and relaunches.');
  assert.equal(changelogSection(CHANGELOG, '0.1.11'), '- Older notes.');
  assert.equal(changelogSection(CHANGELOG, '0.1.13'), null);
});

test('changelogSection does not match a longer version', () => {
  assert.equal(changelogSection('## 0.1.120 - Later\n\n- x\n', '0.1.12'), null);
});

test('changelogTitle reads the words after the version', () => {
  assert.equal(changelogTitle(CHANGELOG, '0.1.12'), 'Updates in the app');
});

test('buildAppcast describes one signed DMG with markdown notes', () => {
  const xml = buildAppcast({
    version: '0.1.12',
    title: 'Updates & more',
    notesMarkdown: '- Notes with ]]> inside',
    downloadUrl: 'https://github.com/datawithfurkan/glasstunnel/releases/download/v0.1.12/Glasstunnel-0.1.12.dmg',
    length: 1234,
    edSignature: 'c2lnbmF0dXJl',
    minimumSystemVersion: '13.0',
    pubDate: 'Thu, 29 Oct 2026 10:00:00 GMT',
  });

  assert.match(xml, /<sparkle:version>0\.1\.12<\/sparkle:version>/);
  assert.match(xml, /<sparkle:minimumSystemVersion>13\.0<\/sparkle:minimumSystemVersion>/);
  assert.match(xml, /<title>Glasstunnel 0\.1\.12: Updates &amp; more<\/title>/);
  assert.match(xml, /<description sparkle:format="markdown"><!\[CDATA\[- Notes with \]\]\]\]><!\[CDATA\[> inside\]\]><\/description>/);
  assert.match(xml, /length="1234" type="application\/octet-stream" sparkle:edSignature="c2lnbmF0dXJl"/);
  assert.equal((xml.match(/<item>/g) ?? []).length, 1);
});
