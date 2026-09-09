'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..', '..');
const rendererPath = path.join(root, 'Sources', 'MarkdownRenderer.swift');
const markdownItPath = path.join(root, 'Sources', 'Resources', 'markdown-it.min.js');
const resourcePath = name => path.join(root, 'Sources', 'Resources', name);

const APP_CONFIG = Object.freeze({
  html: true,
  linkify: true,
  typographer: true,
  breaks: true
});

// CommonMark's reference HTML uses XHTML-style void tags (`<br />`, `<hr />`).
// xhtmlOut only changes serialization; parsing behavior remains the app baseline.
const COMMONMARK_CONFIG = Object.freeze({
  html: true,
  linkify: false,
  typographer: false,
  breaks: false,
  xhtmlOut: true
});

const CONFIGS = Object.freeze({
  app: APP_CONFIG,
  commonmark: COMMONMARK_CONFIG
});

function extractInlineSetup() {
  const swift = fs.readFileSync(rendererPath, 'utf8');
  const functionStart = swift.indexOf('private static func jsRenderInline');
  const rawStart = swift.indexOf('#"""', functionStart);
  const rawEnd = swift.indexOf('"""#', rawStart + 4);
  if (functionStart < 0 || rawStart < 0 || rawEnd < 0) {
    throw new Error('Unable to locate jsRenderInline raw JavaScript in MarkdownRenderer.swift');
  }

  const js = swift.slice(rawStart + 4, rawEnd);
  const srcMarker = js.indexOf('var src = \\#(mdJSON);');
  if (srcMarker < 0) {
    throw new Error('Unable to locate inline render source marker in jsRenderInline');
  }
  return js.slice(0, srcMarker);
}

function replaceConfig(setup, config) {
  const pattern = /window\.__mdit = window\.markdownit\(\{[^}]*\}\);/;
  if (!pattern.test(setup)) {
    throw new Error('Unable to locate markdown-it configuration in jsRenderInline');
  }
  return setup.replace(pattern, `window.__mdit = window.markdownit(${JSON.stringify(config)});`);
}

function loadResource(window, filename) {
  const context = {
    window,
    self: window,
    globalThis: window,
    document: { compatMode: 'CSS1Compat' },
    console
  };
  window.window = window;
  vm.runInNewContext(fs.readFileSync(resourcePath(filename), 'utf8'), context, { filename });
}

function loadRenderer(profile = 'app') {
  const config = CONFIGS[profile];
  if (!config) {
    throw new Error(`Unknown renderer profile: ${profile}`);
  }

  const setup = replaceConfig(extractInlineSetup(), config);
  const window = { markdownit: require(markdownItPath) };

  if (profile === 'app') {
    loadResource(window, 'markdown-it-footnote.min.js');
    loadResource(window, 'md-plugins.min.js');
    loadResource(window, 'katex.min.js');
  }

  const factory = new Function(
    'window',
    'var result;\n' + setup + '\nresult = window.__mdit;\n} catch(err) { throw err; }\n})();\nreturn result;'
  );
  return factory(window);
}

function normalizeQuoteVariants(html) {
  return html.replace(/(?:&quot;|&#34;|&ldquo;|&rdquo;|[“”])/g, '"');
}

module.exports = {
  APP_CONFIG,
  COMMONMARK_CONFIG,
  loadRenderer,
  normalizeQuoteVariants,
  root
};
