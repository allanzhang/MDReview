'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {
  loadRenderer,
  normalizeQuoteVariants,
  root
} = require('./load-renderer');

function render(md, testCase) {
  return testCase.mode === 'block'
    ? md.render(testCase.markdown)
    : md.renderInline(testCase.markdown);
}

function runFixtureFile(relativePath) {
  const fixturePath = path.join(root, 'Tests', 'fixtures', 'renderer', relativePath);
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const md = loadRenderer(fixture.profile || 'app');
  let count = 0;

  for (const testCase of fixture.cases) {
    const html = render(md, testCase);
    const actual = testCase.normalizeQuotes ? normalizeQuoteVariants(html) : html;

    if (Object.prototype.hasOwnProperty.call(testCase, 'expected')) {
      const expected = testCase.normalizeQuotes
        ? normalizeQuoteVariants(testCase.expected)
        : testCase.expected;
      assert.strictEqual(actual, expected, `${relativePath}: ${testCase.name}`);
    }

    for (const expectedPart of testCase.contains || []) {
      assert.ok(actual.includes(expectedPart), `${relativePath}: ${testCase.name} missing ${JSON.stringify(expectedPart)}`);
    }

    for (const forbiddenPart of testCase.notContains || []) {
      assert.ok(!actual.includes(forbiddenPart), `${relativePath}: ${testCase.name} unexpectedly contains ${JSON.stringify(forbiddenPart)}`);
    }

    count++;
  }

  return count;
}

module.exports = { runFixtureFile };
