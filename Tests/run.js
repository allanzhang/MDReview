#!/usr/bin/env node
'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

const suites = [
  'markdown-renderer-regression.js',
  'punctuation-boundary.js',
  'app-extensions.js',
  'commonmark-conformance.js'
];

for (const suite of suites) {
  const result = spawnSync(process.execPath, [path.join(__dirname, suite)], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}

console.log(`ok - renderer test suite (${suites.length} suites)`);
