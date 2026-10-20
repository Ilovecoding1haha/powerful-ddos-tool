'use strict';

module.exports = {
  'http-get': require('./http-get'),
  'http-post': require('./http-post'),
  'http-head': require('./http-head'),
  'http2': require('./http2'),
  'slowloris': require('./slowloris'),
  'range': require('./range'),
  'random': require('./random'),
  'tcp': require('./tcp'),
  'udp': require('./udp'),
  'dns': require('./dns'),
};
