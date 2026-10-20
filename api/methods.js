'use strict';
const METHODS = require('../lib/methods');

module.exports = function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.status(200).json({
    ok: true,
    count: Object.keys(METHODS).length,
    presets: { mix: 'six fastest Layer-7 methods at once', all: 'all ten methods at once' },
    methods: Object.entries(METHODS).map(([id, m]) => ({
      id, name: m.name, layer: m.layer, summary: m.summary, defaults: m.defaults || {},
    })),
  });
};
