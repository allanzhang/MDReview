#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const catalogPath = path.join(root, 'Sources', 'Resources', 'Localizable.xcstrings');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const entries = catalog.strings || {};
const failures = [];

function extractStrings(line) {
  return [...line.matchAll(/"((?:\\.|[^"\\])*)"/g)].map((match) => match[1]);
}

const files = fs.readdirSync(path.join(root, 'Sources'))
  .filter((name) => name.endsWith('.swift'))
  .map((name) => path.join(root, 'Sources', name));

for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (trimmed.startsWith('//') || trimmed.startsWith('///')) return;
    const location = `${path.relative(root, file)}:${index + 1}`;

    const checks = [
      { re: /\bText\("([^"]*)"\)/g, name: 'Text' },
      { re: /\bButton\("([^"]*)"\)/g, name: 'Button' },
      { re: /\bLabel\("([^"]*)"\s*,\s*systemImage:/g, name: 'Label' },
      { re: /\.help\("([^"]*)"\)/g, name: '.help' },
      { re: /\.navigationTitle\("([^"]*)"\)/g, name: '.navigationTitle' },
      { re: /messageText\s*=\s*"([^"]*)"/g, name: 'NSAlert.messageText' },
      { re: /informativeText\s*=\s*"([^"]*)"/g, name: 'NSAlert.informativeText' },
      { re: /placeholderString\s*=\s*"([^"]*)"/g, name: 'placeholderString' },
      { re: /window\.title\s*=\s*"([^"]*)"/g, name: 'window.title' }
    ];

    for (const check of checks) {
      for (const match of line.matchAll(check.re)) {
        const key = match[1];
        if (!key || key.includes('\\(') || key === '') continue;
        if (!entries[key]) failures.push(`${location} ${check.name} key is missing from Localizable.xcstrings: ${key}`);
      }
    }

    for (const match of line.matchAll(/L10n\.(?:string|format)\(\s*"((?:\\.|[^"\\])*)"/g)) {
      const key = match[1];
      if (!key || key.includes('\\(')) continue;
      if (!entries[key]) failures.push(`${location} L10n key is missing from Localizable.xcstrings: ${key}`);
    }
  });
}

for (const [key, entry] of Object.entries(entries)) {
  for (const language of ['en', 'zh-Hans']) {
    const value = entry.localizations?.[language]?.stringUnit?.value;
    if (typeof value !== 'string' || value.length === 0) {
      failures.push(`Localizable.xcstrings is missing ${language} for key: ${key}`);
    }
  }
}

if (failures.length > 0) {
  console.error('not ok - localization contract');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(`ok - localization contract (${Object.keys(entries).length} keys)`);
