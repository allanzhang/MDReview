#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function runSwiftVersionTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-update-version-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'UpdateVersion.swift'),
    path.join(__dirname, 'UpdateVersionTests.swift'),
    '-o', output
  ], { stdio: 'inherit' });

  if (compile.error) throw compile.error;
  if (compile.status !== 0) process.exit(compile.status || 1);

  const run = spawnSync(output, [], { stdio: 'inherit' });
  fs.rmSync(moduleCache, { recursive: true, force: true });
  fs.rmSync(output, { force: true });

  if (run.error) throw run.error;
  if (run.status !== 0) process.exit(run.status || 1);
}

function runSwiftIntegrityTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-update-integrity-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-parse-as-library',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'UpdateIntegrity.swift'),
    path.join(__dirname, 'UpdateIntegrityTests.swift'),
    '-o', output
  ], { stdio: 'inherit' });

  if (compile.error) throw compile.error;
  if (compile.status !== 0) process.exit(compile.status || 1);

  const run = spawnSync(output, [], { stdio: 'inherit' });
  fs.rmSync(moduleCache, { recursive: true, force: true });
  fs.rmSync(output, { force: true });

  if (run.error) throw run.error;
  if (run.status !== 0) process.exit(run.status || 1);
}

runSwiftVersionTests();
runSwiftIntegrityTests();

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
