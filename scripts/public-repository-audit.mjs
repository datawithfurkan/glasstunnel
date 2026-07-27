#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { extname } from 'node:path';

const root = new URL('../', import.meta.url).pathname.replace(/\/$/, '');
const failures = [];

function trackedFiles() {
  return execFileSync('git', ['ls-files', '-z'], { cwd: root })
    .toString('utf8')
    .split('\0')
    .filter(Boolean);
}

function addFailure(category, path, line, detail) {
  failures.push({ category, path, line, detail });
}

function lineFor(content, offset) {
  return content.slice(0, offset).split('\n').length;
}

const requiredFiles = [
  'README.md',
  'LICENSE',
  'CONTRIBUTING.md',
  'SECURITY.md',
  'CODE_OF_CONDUCT.md',
  'CHANGELOG.md',
  'docs/public-visibility-checklist.md',
  'docs/agent-app-support-matrix.md',
  'docs/known-limitations.md',
];

const privateOwner = ['fur', 'kan'].join('');
const privateSurname = ['Ke', 'sen'].join('');
const privateVolume = ['Work', 'Drive'].join('');

const privatePatterns = [
  ['personal email', /[A-Z0-9._%+-]+@(?:gmail|icloud|me|outlook|hotmail)\.(?:com|de|net)/giu],
  ['private home path', new RegExp(`/Users/${privateOwner}(?:/|\\b)`, 'gu')],
  ['private volume path', new RegExp(`/Volumes/${privateVolume}(?:/|\\b)`, 'gu')],
  [
    'private machine name',
    new RegExp(`${privateOwner}s-mac-mini|${privateOwner}(?:'|’)s Mac (?:mini|book air)`, 'giu'),
  ],
  ['private full name', new RegExp(`${privateOwner} ${privateSurname}`, 'giu')],
];

const credentialPatterns = [
  ['Telegram bot token', /\b\d{8,12}:[A-Za-z0-9_-]{30,}\b/gu],
  ['GitHub token', /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b/gu],
  ['OpenAI-style key', /\bsk-[A-Za-z0-9_-]{20,}\b/gu],
  ['JWT', /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu],
];

const forbiddenEvidenceExtensions = new Set([
  '.html',
  '.json',
  '.jpg',
  '.jpeg',
  '.mov',
  '.mp4',
  '.png',
  '.trace',
  '.webm',
  '.zip',
]);

const files = trackedFiles();
const fileSet = new Set(files);

for (const path of requiredFiles) {
  if (!fileSet.has(path))
    addFailure('missing community file', path, 0, 'required public file is not tracked');
}

for (const path of files) {
  const absolute = `${root}/${path}`;
  let stat;
  try {
    stat = statSync(absolute);
  } catch {
    addFailure('missing tracked file', path, 0, 'tracked path is absent from the working tree');
    continue;
  }

  if (stat.size > 1_048_576) {
    addFailure(
      'oversized tracked file',
      path,
      0,
      `${stat.size} bytes exceeds the 1 MiB public-tree limit`,
    );
  }
  if (path.endsWith('.md') && stat.size > 262_144) {
    addFailure(
      'oversized documentation',
      path,
      0,
      `${stat.size} bytes exceeds the 256 KiB documentation limit`,
    );
  }
  if (
    path.startsWith('docs/release-evidence/') &&
    forbiddenEvidenceExtensions.has(extname(path).toLowerCase())
  ) {
    addFailure(
      'raw release evidence',
      path,
      0,
      'raw browser/media artifacts must remain in ignored local storage',
    );
  }
  if (
    path.includes('/dev-dist/') ||
    path.startsWith('docs/archive/') ||
    path.startsWith('docs/superpowers/')
  ) {
    addFailure(
      'generated or internal artifact',
      path,
      0,
      'generated/internal history is not part of the public source tree',
    );
  }

  if (stat.size === 0 || stat.size > 1_048_576) continue;
  const buffer = readFileSync(absolute);
  if (buffer.includes(0)) continue;
  const content = buffer.toString('utf8');

  for (const [label, pattern] of [...privatePatterns, ...credentialPatterns]) {
    pattern.lastIndex = 0;
    for (const match of content.matchAll(pattern)) {
      addFailure(
        label,
        path,
        lineFor(content, match.index ?? 0),
        'matched value intentionally redacted',
      );
    }
  }
}

if (failures.length > 0) {
  console.error('Public repository audit failed. Matched values are not printed.');
  for (const failure of failures) {
    const location = failure.line > 0 ? `${failure.path}:${failure.line}` : failure.path;
    console.error(`- ${failure.category}: ${location} (${failure.detail})`);
  }
  process.exit(1);
}

console.log(`Public repository audit passed for ${files.length} tracked files.`);
