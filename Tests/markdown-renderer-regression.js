#!/usr/bin/env node
'use strict';

const { runFixtureFile } = require('./lib/fixture-runner');

const fixtures = [
  'punct-strong.json',
  'historical-issues.json',
  'real-world.json'
];

let count = 0;
for (const fixture of fixtures) {
  count += runFixtureFile(fixture);
}

console.log(`ok - ${count} renderer golden fixtures across ${fixtures.length} fixture files`);
