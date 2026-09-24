#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

function compileAndRun(name, files, { parseAsLibrary = false, frameworks = [] } = {}) {
  const moduleCache = fs.mkdtempSync(path.join(os.tmpdir(), 'mdreview-swift-cache-'));
  const output = path.join(os.tmpdir(), `mdreview-${name}-${process.pid}`);
  const args = ['-swift-version', '5', '-module-cache-path', moduleCache];
  if (parseAsLibrary) args.push('-parse-as-library');
  for (const fw of frameworks) args.push('-framework', fw);
  args.push(...files, '-o', output);
  const compile = spawnSync('swiftc', args, { stdio: 'inherit' });
  if (compile.error) throw compile.error;
  if (compile.status !== 0) process.exit(compile.status || 1);
  const run = spawnSync(output, [], { stdio: 'inherit' });
  fs.rmSync(moduleCache, { recursive: true, force: true });
  fs.rmSync(output, { force: true });
  if (run.error) throw run.error;
  if (run.status !== 0) process.exit(run.status || 1);
}

function runSwiftVersionTests() {
  compileAndRun('update-version-tests', [
    path.join(__dirname, '..', 'Sources', 'UpdateVersion.swift'),
    path.join(__dirname, 'UpdateVersionTests.swift')
  ]);
}

function runAppLanguageTests() {
  compileAndRun('app-language-tests', [
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, 'AppLanguageTests.swift')
  ]);
}

function runDocStateTests() {
  compileAndRun('docstate-tests', [
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, '..', 'Sources', 'Localization.swift'),
    path.join(__dirname, '..', 'Sources', 'DocState.swift'),
    path.join(__dirname, 'TestRunner.swift'),
    path.join(__dirname, 'DocStateTests.swift')
  ], { parseAsLibrary: true, frameworks: ['AppKit', 'SwiftUI'] });
}

function runAboutLinksTests() {
  compileAndRun('about-links-tests', [
    path.join(__dirname, '..', 'Sources', 'AboutLinks.swift'),
    path.join(__dirname, 'AboutLinksTests.swift')
  ]);
}

function runMainMenuLocalizerTests() {
  compileAndRun('main-menu-localizer-tests', [
    path.join(__dirname, '..', 'Sources', 'AppLanguage.swift'),
    path.join(__dirname, '..', 'Sources', 'Localization.swift'),
    path.join(__dirname, '..', 'Sources', 'MainMenuLocalizer.swift'),
    path.join(__dirname, 'MainMenuLocalizerTests.swift')
  ], { frameworks: ['AppKit'] });
}

function runSwiftIntegrityTests() {
  compileAndRun('update-integrity-tests', [
    path.join(__dirname, '..', 'Sources', 'UpdateIntegrity.swift'),
    path.join(__dirname, 'UpdateIntegrityTests.swift')
  ], { parseAsLibrary: true });
}

function runMarkdownFileDropTests() {
  compileAndRun('file-drop-tests', [
    path.join(__dirname, '..', 'Sources', 'MarkdownFileDrop.swift'),
    path.join(__dirname, 'MarkdownFileDropTests.swift')
  ], { frameworks: ['AppKit'] });
}

function runCodeFoldAndDropContractTests() {
  const renderer = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'MarkdownRenderer.swift'), 'utf8');
  const content = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'ContentView.swift'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'Resources', 'reader.css'), 'utf8');
  const failures = [];

  const polishStart = renderer.indexOf('window.__polishCodeBlocks');
  const polishEnd = renderer.indexOf('window.__mdit.renderSection', polishStart);
  if (polishStart < 0 || polishEnd < 0) {
    failures.push('unable to locate __polishCodeBlocks');
  } else {
    const polish = renderer.slice(polishStart, polishEnd);
    if (/\bvar pre\s*=/.test(polish)) {
      failures.push('code-block fold must not capture pre with var');
    }
    if (!/\blet pre\s*=/.test(polish)) {
      failures.push('code-block fold must bind pre with let per iteration');
    }
    if (!polish.includes("header.className = 'code-lang'")) {
      failures.push('code-block fold must use a real .code-lang header');
    }
    if (!polish.includes('header.addEventListener')) {
      failures.push('code-block fold must bind click on the header, not a shared pre');
    }
  }

  if (!css.includes('pre.code-block .code-lang')) {
    failures.push('reader.css must style the real language header');
  }
  if (/pre\.code-block::before[\s\S]{0,200}pointer-events:\s*none/.test(css)) {
    failures.push('language bar must receive clicks');
  }

  if (content.includes('ReaderWebView(renderer: renderer)') && /ReaderWebView\(renderer: renderer\)\s*\n\s*\.onDrop/.test(content)) {
    failures.push('onDrop must not sit only on ReaderWebView under EmptyStateView');
  }
  if (!content.includes('.onDrop(of: [.fileURL]')) {
    failures.push('window must accept dropped file URLs');
  }
  if (!content.includes('MarkdownFileDrop.url(fromLoadedItem:')) {
    failures.push('SwiftUI drop must parse loaded items through MarkdownFileDrop');
  }
  if (!renderer.includes('performDragOperation')) {
    failures.push('WKWebView must implement performDragOperation for markdown files');
  }
  if (!renderer.includes('decidePolicyFor navigationAction')) {
    failures.push('WKWebView must intercept dropped markdown navigations');
  }

  if (failures.length > 0) {
    console.error('not ok - code fold and drop contract');
    for (const failure of failures) console.error(`  - ${failure}`);
    process.exit(1);
  }
  console.log('ok - code fold and drop contract');
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

function runViewStructureContractTests() {
  const recent = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'RecentView.swift'), 'utf8');
  const outline = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'OutlineView.swift'), 'utf8');
  const content = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'ContentView.swift'), 'utf8');
  const docState = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'DocState.swift'), 'utf8');
  const failures = [];

  // 最近列表行不能是 Button：Button 的 action 在右键时也会触发，弹出菜单的同时读盘重渲染，主线程被堵数秒。
  // 打开动作必须由 onTapGesture 承担，右键只留给 contextMenu。
  if (recent.includes('Button(action: action)')) {
    failures.push('RecentView: 行不能用 Button，右键会同时触发打开并卡死主线程，改用 onTapGesture');
  }
  if (!recent.includes('.onTapGesture(perform: action)')) {
    failures.push('RecentView: 缺少 onTapGesture 承担左键打开');
  }

  // clearRecent 必须同时清除 lastUrl，否则重启会恢复刚清空的最后一篇文档。
  const clearStart = docState.indexOf('func clearRecent()');
  const clearBody = docState.slice(clearStart, docState.indexOf('\n    func ', clearStart + 1));
  if (!clearBody.includes('lastUrlKey')) {
    failures.push('DocState.clearRecent() 必须清除 lastUrlKey，否则重启时 restoreLastDocument 会重新打开已清空的文档');
  }

  if (failures.length > 0) {
    for (const f of failures) console.error(`FAIL - ${f}`);
    process.exit(1);
  }
  console.log('ok - view structure contracts');
}

runSwiftVersionTests();
runAppLanguageTests();
runAboutLinksTests();
runMainMenuLocalizerTests();
runSwiftIntegrityTests();
runDocStateTests();
runMarkdownFileDropTests();
runCodeFoldAndDropContractTests();
runViewStructureContractTests();
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
