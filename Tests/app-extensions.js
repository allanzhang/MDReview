#!/usr/bin/env node
'use strict';

const { runFixtureFile } = require('./lib/fixture-runner');

const count = runFixtureFile('app-extensions.json');
console.log(`ok - ${count} app extension golden cases`);
