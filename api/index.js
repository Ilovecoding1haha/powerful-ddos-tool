'use strict';
const METHODS = require('../lib/methods');

module.exports = function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.status(200).json({
    name: 'venice-ddos',
    version: '3.0.0',
    methods: Object.keys(METHODS),
    endpoints: {
      attack: '/api/attack?target=<host>&method=<id>&duration=<sec>&concurrency=<n>',
      methods: '/api/methods',
      status: '/api/status',
    },
    params: {
      target: 'host, host:port, or full URL (required)',
      method: 'method id, comma-separated list, "mix", or "all" (default http-get)',
      duration: 'seconds, 1-800 (default 15)',
      concurrency: 'parallel sockets, 1-900 (default per method)',
      port: 'override port',
      payloadSize: 'UDP datagram size in bytes',
      sessions: 'HTTP/2 session count',
      slowInterval: 'ms between Slowloris pads',
      stream: '1 = live NDJSON ticks',
      async: '1 = return immediately, blast in background',
    },
  });
};
