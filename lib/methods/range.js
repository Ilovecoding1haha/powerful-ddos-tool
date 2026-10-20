'use strict';
const { createHttpMethod } = require('./_http');

module.exports = {
  name: 'HTTP-RANGE',
  layer: 7,
  summary: 'GET with Range: bytes=0-1. Tiny 206 responses, maximum requests per socket.',
  defaults: { concurrency: 800 },
  create(ctx) {
    return createHttpMethod(ctx, () => ({
      method: 'GET',
      path: ctx.target.path,
      headers: { Range: 'bytes=0-1' },
    }));
  },
};
