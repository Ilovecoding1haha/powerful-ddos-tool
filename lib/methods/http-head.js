'use strict';
const { createHttpMethod } = require('./_http');

module.exports = {
  name: 'HTTP-HEAD',
  layer: 7,
  summary: 'HEAD flood. No response body means the highest requests/sec achievable.',
  defaults: { concurrency: 800 },
  create(ctx) {
    return createHttpMethod(ctx, () => ({ method: 'HEAD', path: ctx.target.path }));
  },
};
