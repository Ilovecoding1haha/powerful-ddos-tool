'use strict';

module.exports = function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.status(200).json({
    ok: true,
    lastRun: globalThis.__VENICE_DDOS_LAST || null,
    instance: { node: process.version, uptime: Math.round(process.uptime()), rssMb: Math.round(process.memoryUsage().rss / 1048576) },
    note: 'State is per warm instance; /api/status only reflects runs that landed on this same one.',
  });
};
