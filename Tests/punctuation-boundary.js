#!/usr/bin/env node
'use strict';

const assert = require('assert');
const { loadRenderer } = require('./lib/load-renderer');

const md = loadRenderer('app');

const patterns = [
  ['both inside', ch => `A**${ch}X${ch}**B`],
  ['opening inside', ch => `A**${ch}X**B`],
  ['closing inside', ch => `A**X${ch}**B`],
  ['punctuation only', ch => `A**${ch}**B`],
  ['punctuation after close', ch => `A**X**${ch}B`],
  ['punctuation before open', ch => `A${ch}**X**B`],
  ['line start', ch => `**${ch}X**`],
  ['line end', ch => `**X${ch}**`],
  ['both outside', ch => `A${ch}**${ch}X${ch}**${ch}B`]
];

// These characters participate in Markdown syntax themselves. They are covered
// by dedicated fixtures (escapes, code spans, triple emphasis, nested syntax)
// rather than being treated as ordinary punctuation in this matrix.
const markdownSyntaxChars = new Set([
  '*', '\\', '`', '[', ']', '(', ')', '_', '~', '$', '^', '=', '<', '>', '&', '!'
]);

let count = 0;
let punctuationCount = 0;
for (let codePoint = 0; codePoint <= 0x10FFFF; codePoint++) {
  if (codePoint >= 0xD800 && codePoint <= 0xDFFF) continue;
  const ch = String.fromCodePoint(codePoint);
  if (!/[\p{P}\p{S}]/u.test(ch)) continue;
  if (markdownSyntaxChars.has(ch)) continue;

  punctuationCount++;
  for (const [name, makeMarkdown] of patterns) {
    const html = md.renderInline(makeMarkdown(ch));
    assert.ok(!html.includes('**'), `${name} leaked raw ** for U+${codePoint.toString(16).toUpperCase()}`);
    assert.ok(html.includes('<strong>'), `${name} did not produce strong for U+${codePoint.toString(16).toUpperCase()}`);
    count++;
  }
}

console.log(`ok - ${count} Unicode punctuation/symbol boundary combinations (${punctuationCount} code points x ${patterns.length} patterns)`);
