'use strict';

class Stats {
  constructor() { this.reset(); }

  reset() {
    this.reqs = 0;
    this.bytes = 0;
    this.errors = 0;
    this.conns = 0;
    this.connsOpened = 0;
    this.startedAt = Date.now();
    this.last = { t: Date.now(), reqs: 0, bytes: 0, errors: 0 };
  }

  hit(bytes = 0) { this.reqs++; this.bytes += bytes; }
  err() { this.reqs++; this.errors++; }
  open() { this.conns++; this.connsOpened++; }
  close() { this.conns--; }

  snapshot() {
    const now = Date.now();
    const dt = Math.max(1, now - this.last.t) / 1000;
    const dReqs = this.reqs - this.last.reqs;
    const dBytes = this.bytes - this.last.bytes;
    const dErr = this.errors - this.last.errors;
    this.last = { t: now, reqs: this.reqs, bytes: this.bytes, errors: this.errors };

    return {
      uptime: (now - this.startedAt) / 1000,
      total: {
        reqs: this.reqs,
        bytes: this.bytes,
        errors: this.errors,
        connsOpen: this.conns,
        connsOpened: this.connsOpened,
      },
      rate: {
        rps: dReqs / dt,
        bps: (dBytes * 8) / dt,   // bits, not bytes
        errorsPerSec: dErr / dt,
      },
    };
  }
}

module.exports = { Stats };
