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

function runAppLanguageTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-app-language-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, 'AppLanguageTests.swift'),
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

function runDocStateLanguageTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-doc-state-language-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-parse-as-library',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, '..', 'Sources', 'Localization.swift'),
    path.join(__dirname, '..', 'Sources', 'DocState.swift'),
    path.join(__dirname, 'DocStateLanguageTests.swift'),
    '-framework', 'AppKit',
    '-framework', 'SwiftUI',
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

function runAboutLinksTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-about-links-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'AboutLinks.swift'),
    path.join(__dirname, 'AboutLinksTests.swift'),
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

function runMainMenuLocalizerTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-main-menu-localizer-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, '..', 'Sources', 'Localization.swift'),
    path.join(__dirname, '..', 'Sources', 'MainMenuLocalizer.swift'),
    path.join(__dirname, 'MainMenuLocalizerTests.swift'),
    '-framework', 'AppKit',
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

function runSingleWindowSceneTests() {
  const appSource = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'MDReviewApp.swift'), 'utf8');
  const contentSource = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'ContentView.swift'), 'utf8');
  const failures = [];

  if (!appSource.includes('Window("MDReview", id: "main")')) {
    failures.push('main scene must be a single Window("MDReview", id: "main")');
  }
  if (appSource.includes('WindowGroup')) {
    failures.push('WindowGroup must not be used because it allows multiple windows');
  }
  if (!appSource.includes('frameAutosaveName == MainWindow.autosaveName')) {
    failures.push('Finder open flow must identify and raise the main window');
  }
  if (!contentSource.includes('setFrameAutosaveName(MainWindow.autosaveName)')) {
    failures.push('main window must use the shared frame autosave name');
  }
  if (!appSource.includes('NSLocale.currentLocaleDidChangeNotification')) {
    failures.push('app must observe system locale changes while running');
  }
  if (!appSource.includes('DocState.shared.refreshSystemLanguage()')) {
    failures.push('locale and activation events must refresh Follow System state');
  }
  const localeHandler = appSource.match(/@objc private func systemLocaleDidChange\([^)]*\)\s*\{([\s\S]*?)\n\s*\}/);
  if (!localeHandler || !localeHandler[1].includes('DocState.shared.refreshSystemLanguage()')) {
    failures.push('system locale callback must refresh Follow System state');
  }
  const activationHandler = appSource.match(/@objc private func appDidBecomeActive\([^)]*\)\s*\{([\s\S]*?)\n\s*\}/);
  if (!activationHandler || !activationHandler[1].includes('DocState.shared.refreshSystemLanguage()')) {
    failures.push('application activation callback must recheck Follow System state');
  }
  for (const forbidden of [
    'relaunchForLanguageChange',
    'openApplication(',
    'createsNewApplicationInstance',
    'NSApp.terminate(nil)'
  ]) {
    if (appSource.includes(forbidden)) {
      failures.push(`language switching must not contain relaunch path: ${forbidden}`);
    }
  }

  if (failures.length > 0) {
    console.error('not ok - single main window scene contract');
    for (const failure of failures) console.error(`  - ${failure}`);
    process.exit(1);
  }
  console.log('ok - single main window scene contract');
}

function runSwiftFileMonitorTests() {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-file-monitor-tests-${process.pid}`);
  const compile = spawnSync('swiftc', [
    '-swift-version', '5',
    '-parse-as-library',
    '-module-cache-path', moduleCache,
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, '..', 'Sources', 'Localization.swift'),
    path.join(__dirname, '..', 'Sources', 'DocState.swift'),
    path.join(__dirname, 'DocStateFileMonitorTests.swift'),
    '-framework', 'AppKit',
    '-framework', 'SwiftUI',
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
runAppLanguageTests();
runAboutLinksTests();
runMainMenuLocalizerTests();
runSwiftIntegrityTests();
runDocStateLanguageTests();
runSwiftFileMonitorTests();
runSingleWindowSceneTests();

const suites = [
  'localization.js',
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
