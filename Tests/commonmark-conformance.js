#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { loadRenderer, root } = require('./lib/load-renderer');

const specPath = path.join(root, 'Tests', 'fixtures', 'commonmark', 'spec.json');
const divergencePath = path.join(root, 'Tests', 'fixtures', 'commonmark', 'divergences.json');
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
const divergences = JSON.parse(fs.readFileSync(divergencePath, 'utf8'));
const md = loadRenderer('commonmark');

const divergenceByExample = new Map(divergences.map(item => [item.example, item]));
const seenDivergences = new Set();
const unexpectedFailures = [];
let exact = 0;

for (const example of spec) {
  const actual = md.render(example.markdown);
  if (actual === example.html) {
    if (divergenceByExample.has(example.example)) {
      assert.fail(`CommonMark divergence for example ${example.example} is stale: output now matches the spec`);
    }
    exact++;
    continue;
  }

  const divergence = divergenceByExample.get(example.example);
  if (!divergence) {
    unexpectedFailures.push({
      example: example.example,
      section: example.section,
      expected: example.html,
      actual
    });
    continue;
  }

  assert.strictEqual(
    actual,
    divergence.actual,
    `CommonMark example ${example.example} changed from its documented divergence`
  );
  seenDivergences.add(example.example);
}

if (unexpectedFailures.length > 0) {
  const details = unexpectedFailures.map(item => [
    `example ${item.example} (${item.section})`,
    `expected: ${JSON.stringify(item.expected)}`,
    `actual:   ${JSON.stringify(item.actual)}`
  ].join('\n')).join('\n\n');
  assert.fail(`${unexpectedFailures.length} unexpected CommonMark divergence(s):\n\n${details}`);
}

assert.strictEqual(seenDivergences.size, divergences.length, 'Every documented divergence must match a failing CommonMark example');
console.log(`ok - ${spec.length} CommonMark 0.31.2 examples (${exact} exact, ${seenDivergences.size} documented divergences)`);
