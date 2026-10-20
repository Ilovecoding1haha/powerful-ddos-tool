#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p public

cat > public/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>venice-ddos</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0b0c0f;color:#e8eaf0;font:13px/1.6 ui-monospace,Menlo,monospace}
.wrap{max-width:880px;margin:0 auto;padding:26px 16px 60px}
h1{font-size:19px;margin:0 0 2px}
h1 b{color:#7c5cff}
.sub{color:#8b90a0;font-size:11px;margin-bottom:18px}
form{background:#14161c;border:1px solid #252833;border-radius:12px;padding:16px;display:grid;grid-template-columns:1fr 1fr;gap:12px}
label{display:flex;flex-direction:column;gap:5px;font-size:10px;color:#8b90a0;text-transform:uppercase;letter-spacing:.6px}
input,select{background:#0e1015;border:1px solid #252833;color:#e8eaf0;border-radius:7px;padding:9px;font:inherit}
.wide,button{grid-column:1/-1}
button{background:#7c5cff;color:#fff;border:0;border-radius:8px;padding:11px;font:inherit;font-weight:600;cursor:pointer}
button:disabled{opacity:.5}
.bar{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:16px 0}
.stat{background:#14161c;border:1px solid #252833;border-radius:10px;padding:12px}
.stat b{display:block;font-size:18px}
.stat i{font-style:normal;font-size:10px;color:#8b90a0;text-transform:uppercase}
pre{background:#14161c;border:1px solid #252833;border-radius:10px;padding:14px;overflow:auto;max-height:320px;font-size:11px;margin:0}
.hint{color:#8b90a0;font-size:11px;margin-top:10px;white-space:pre-wrap}
</style>
</head>
<body>
<div class="wrap">
<h1>venice<b>-ddos</b></h1>
<div class="sub">10 methods &middot; layer 4/7</div>

<form id="f">
<label class="wide">Target<input id="target" value="https://example.com" required></label>
<label>Method<select id="method">
<option>http-get</option><option>http-post</option><option>http-head</option><option>http2</option>
<option>slowloris</option><option>range</option><option>random</option><option>tcp</option>
<option>udp</option><option>dns</option><option>mix</option><option>all</option>
</select></label>
<label>Duration (s)<input id="duration" type="number" value="20" min="1" max="800"></label>
<label>Concurrency<input id="concurrency" type="number" value="800" min="1" max="900"></label>
<label>Port<input id="port" type="number" placeholder="auto"></label>
<button id="go">Run attack</button>
</form>

<div class="bar">
<div class="stat"><i>req/s</i><b id="s-rps">-</b></div>
<div class="stat"><i>Mbps</i><b id="s-mbps">-</b></div>
<div class="stat"><i>requests</i><b id="s-req">-</b></div>
<div class="stat"><i>errors</i><b id="s-err">-</b></div>
</div>

<pre id="out">idle</pre>
<div class="hint" id="hint"></div>
</div>

<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var running = false;

  function stats(rps, mbps, err) {
    $('s-rps').textContent = rps;
    $('s-mbps').textContent = mbps;
    $('s-err').textContent = err;
  }

  $('f').addEventListener('submit', async function (e) {
    e.preventDefault();
    if (running) return;
    running = true;
    $('go').disabled = true;
    $('go').textContent = 'Running...';
    $('out').textContent = 'connecting...';
    $('hint').textContent = '';

    var p = new URLSearchParams();
    p.set('target', $('target').value.trim());
    p.set('method', $('method').value);
    p.set('duration', $('duration').value);
    p.set('concurrency', $('concurrency').value);
    p.set('stream', '1');
    if ($('port').value) p.set('port', $('port').value);

    try {
      var res = await fetch('/api/attack?' + p.toString());
      if (!res.ok) throw new Error('API returned HTTP ' + res.status);
      if (!res.body) throw new Error('no stream body');

      var reader = res.body.getReader();
      var dec = new TextDecoder();
      var buf = '';

      for (;;) {
        var r = await reader.read();
        if (r.done) break;
        buf += dec.decode(r.value, { stream: true });
        var lines = buf.split('\n');
        buf = lines.pop();
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim();
          if (!line) continue;
          var msg;
          try { msg = JSON.parse(line); } catch (err) { continue; }

          if (msg.done) {
            var d = msg.result;
            if (d) {
              stats(d.averages.rps.toLocaleString(), d.averages.mbps.toFixed(2), d.totals.errors.toLocaleString());
              $('s-req').textContent = d.totals.requests.toLocaleString();
              $('hint').textContent = 'peak ' + d.peak.rps.toLocaleString() + ' req/s | ' + d.peak.mbps.toFixed(2) + ' Mbps';
            }
            $('out').textContent = JSON.stringify(msg, null, 2);
          } else {
            stats(msg.rps.toLocaleString(), msg.mbps.toFixed(2), msg.errors.toLocaleString());
            $('out').textContent = JSON.stringify(msg);
          }
        }
      }
    } catch (err) {
      $('out').textContent = 'error: ' + err.message;
      $('hint').textContent = 'Open /api/methods in a new tab to confirm the API is live.';
    } finally {
      running = false;
      $('go').disabled = false;
      $('go').textContent = 'Run attack';
    }
  });
})();
</script>
</body>
</html>
HTML

# root copy: covers the case where Vercel serves the repo root instead of public/
cp public/index.html index.html

cat > vercel.json <<'JSON'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "functions": {
    "api/*.js": { "maxDuration": 300, "memory": 1024 }
  }
}
JSON

echo
echo "== sanity check =="
node -e '
const fs = require("fs");
const h = fs.readFileSync("public/index.html", "utf8");
const pairs = [["<style", "</style>"], ["<script", "</script>"], ["<body", "</body>"], ["<html", "</html>"]];
let bad = 0;
for (const [o, c] of pairs) {
  const a = h.split(o).length - 1;
  const b = h.split(c).length - 1;
  console.log("  " + o.padEnd(8) + " " + a + " open, " + b + " close " + (a === b ? "OK" : "MISMATCH"));
  if (a !== b) bad++;
}
console.log("  bytes: " + h.length);
if (bad) { console.error("unbalanced tags -> that is your black screen"); process.exit(1); }
console.log("structure balanced");
'
