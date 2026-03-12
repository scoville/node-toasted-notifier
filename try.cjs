/* eslint-disable @stylistic/js/space-in-parens */

// Build this via `npm run build:node`
const { sum } = require('./build/Release/notifier.node');

console.log(sum(1, 2));
// Should log 3
