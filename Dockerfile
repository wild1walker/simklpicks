FROM node:20-alpine
WORKDIR /app

# Minimal package
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "6.0.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": {
    "node-fetch": "^3.3.2"
  }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src
ENV PORT=7769
EXPOSE 7769

# ---------- src/simkl.js ----------
RUN cat > src/simkl.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api.simkl.com';

function headers() {
  const h = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'simkl-api-key': process.env.SIMKL_API_KEY || ''
  };
  const tok = process.env.SIMKL_ACCESS_TOKEN || '';
  if (tok) h['Authorization'] = `Bearer ${tok}`;
  return h;
}
async function jget(path, q={}) {
  const qs = new URLSearchParams(q).toString();
  const url = API + path + (qs?`?${qs}`:'');
  const r = await fetch(url, { headers: headers() });
  if (!r.ok) throw new Error(`SIMKL ${r.status} ${r.statusText} ${path}`);
  return r.json();
}

export async function lastActivities(){ return jget('/sync/last-activities'); }
export async function hist(kind, page=1, limit=50){ return jget(`/sync/history/${kind}`, { page, limit }); }
export async function ratings(kind){ return jget(`/sync/ratings/${kind}`); }

export function envSummary(){
  return {
    ok:true,
    simklApi: !!process.env.SIMKL_API_KEY,
    simklTok: !!process.env.SIMKL_ACCESS_TOKEN,
    model: process.env.LLM_MODEL || 'meta-llama/llama-3.3-8b-instruct:free'
  };
}
EOF

# ---------- src/oauth.js ----------
RUN cat > src/oauth.js <<'EOF'
import fetch from 'node-fetch';

const AUTH_URL = 'https://simkl.com/oauth/authorize';
const TOKEN_URL = 'https://api.simkl.com/oauth/token';

export function buildAuthorizeUrl() {
  const clientId = process.env.SIMKL_API_KEY || '';
  const redirect = process.env.SIMKL_REDIRECT_URI || '';
  const state = Math.random().toString(36).slice(2);
  const u = new URL(AUTH_URL);
  u.searchParams.set('response_type','code');
  u.searchParams.set('client_id', clientId);
  u.searchParams.set('redirect_uri', redirect);
  u.searchParams.set('state', state);
  return u.toString();
}

export async function exchangeCodeForToken(code) {
  const clientId = process.env.SIMKL_API_KEY || '';
  const clientSecret = process.env.SIMKL_CLIENT_SECRET || '';
  const redirect = process.env.SIMKL_REDIRECT_URI || '';
  // form-urlencoded is most reliable
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    code,
    redirect_uri: redirect,
    grant_type: 'authorization_code'
  }).toString();

  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  const txt = await r.text();
  let j; try{ j = JSON.parse(txt) } catch { j=null }
  return { status:r.status, ok:r.ok, text:txt, json:j };
}
EOF

# ---------- src/index.js ----------
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { envSummary, lastActivities, hist, ratings } from './simkl.js';
import { buildAuthorizeUrl, exchangeCodeForToken } from './oauth.js';

const PORT = Number(process.env.PORT) || 7769;

// Simple HTML page
function page(title, body){
  return `<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:18px}
code,kbd{background:#f4f4f4;padding:2px 4px;border-radius:4px}
a.button{display:inline-block;padding:10px 14px;border-radius:8px;background:#222;color:#fff;text-decoration:none}
pre{white-space:pre-wrap;word-break:break-word;background:#f7f7f7;padding:10px;border-radius:8px}
</style>
</head><body>
<h2>${title}</h2>
${body}
</body></html>`;
}

function send(res, code, data, type='application/json'){
  res.writeHead(code, { 'Content-Type': type, 'Access-Control-Allow-Origin': '*' });
  res.end(data);
}
function sendJSON(res, obj, code=200){ send(res, code, JSON.stringify(obj), 'application/json'); }

const server = http.createServer(async (req, res)=>{
  const u = new URL(req.url, `http://${req.headers.host}`);
  const p = u.pathname;

  if (p === '/' || p === '/health') return send(res, 200, 'ok', 'text/plain');

  if (p === '/setup') {
    const env = envSummary();
    const redirect = process.env.SIMKL_REDIRECT_URI || '';
    const instruct = `
<p>1) In SIMKL developer settings, set Redirect URI to:<br>
<code>${redirect || '(set SIMKL_REDIRECT_URI first)'}</code></p>
<p>2) Tap Start to authorize, then you will be redirected back here. We will exchange the code and show your access token.</p>
<p><a class="button" href="/auth/start">Start SIMKL Authorization</a></p>
<h3>Environment</h3>
<pre>${JSON.stringify(env, null, 2)}</pre>
<p>Quick tests after success:</p>
<ul>
<li><a href="/simkl-stats">/simkl-stats</a></li>
<li><a href="/simkl-history">/simkl-history</a></li>
<li><a href="/simkl-ratings">/simkl-ratings</a></li>
</ul>`;
    return send(res, 200, page('SIMKL Setup', instruct), 'text/html');
  }

  if (p === '/auth/start') {
    const url = buildAuthorizeUrl();
    res.writeHead(302, { 'Location': url });
    return res.end();
  }

  if (p === '/simkl/callback') {
    const code = u.searchParams.get('code');
    if (!code) return send(res, 400, page('SIMKL Callback', '<p>No <code>code</code> provided.</p>'), 'text/html');
    try {
      const out = await exchangeCodeForToken(code);
      let msg = `<p>Status: ${out.status} (${out.ok ? 'ok' : 'error'})</p>`;
      if (out.ok && out.json?.access_token) {
        // Activate runtime immediately
        process.env.SIMKL_ACCESS_TOKEN = out.json.access_token;
        msg += `<p><b>Access Token</b> (copy this into Koyeb as <code>SIMKL_ACCESS_TOKEN</code>):</p>
<pre>${out.json.access_token}</pre>
<p>Now test:</p>
<ul>
<li><a href="/env-check">/env-check</a></li>
<li><a href="/simkl-stats">/simkl-stats</a></li>
<li><a href="/simkl-history">/simkl-history</a></li>
<li><a href="/simkl-ratings">/simkl-ratings</a></li>
</ul>`;
      } else {
        msg += `<p>Raw response:</p><pre>${out.text}</pre>
<p>Most common causes: redirect mismatch, reused/expired code, or wrong client secret.</p>`;
      }
      return send(res, 200, page('SIMKL Token Result', msg), 'text/html');
    } catch (e) {
      return send(res, 500, page('SIMKL Callback Error', `<pre>${String(e)}</pre>`), 'text/html');
    }
  }

  // Existing JSON helpers
  if (p === '/env-check') return sendJSON(res, envSummary());
  if (p === '/simkl-stats') {
    try {
      const la = await lastActivities().catch(()=>null);
      const [m,s,a] = await Promise.all([
        hist('movies').catch(()=>[]),
        hist('shows').catch(()=>[]),
        hist('anime').catch(()=>[])
      ]);
      const [rm,rs,ra] = await Promise.all([
        ratings('movies').catch(()=>[]),
        ratings('shows').catch(()=>[]),
        ratings('anime').catch(()=>[])
      ]);
      return sendJSON(res, {
        ok:true, lastActivities: la || null,
        movies:{history:Array.isArray(m)?m.length:0, ratings:Array.isArray(rm)?rm.length:0},
        series:{history:Array.isArray(s)?s.length:0, ratings:Array.isArray(rs)?rs.length:0},
        anime: {history:Array.isArray(a)?a.length:0, ratings:Array.isArray(ra)?ra.length:0}
      });
    } catch { return sendJSON(res, { ok:false }); }
  }
  if (p === '/simkl-history') {
    const [m,s,a] = await Promise.all([
      hist('movies').catch(()=>[]), hist('shows').catch(()=>[]), hist('anime').catch(()=>[])
    ]);
    return sendJSON(res, { movies:m, shows:s, anime:a });
  }
  if (p === '/simkl-ratings') {
    const [m,s,a] = await Promise.all([
      ratings('movies').catch(()=>[]), ratings('shows').catch(()=>[]), ratings('anime').catch(()=>[])
    ]);
    return sendJSON(res, { movies:m, shows:s, anime:a });
  }

  // Stremio manifest placeholder (kept simple)
  if (p === '/manifest' || p === '/manifest.json') {
    return sendJSON(res, {
      id: 'org.simkl.picks',
      version: '6.0.0',
      name: 'SimklPicks (OAuth UI)',
      description: 'AI recommendations based on SIMKL; includes built-in OAuth UI at /setup',
      resources: ['catalog'],
      types: ['movie','series'],
      idPrefixes: ['tvdb'],
      catalogs: [
        { type:'movie', id:'simklpicks.recommended-movies', name:'Simkl Picks • Movies' },
        { type:'series', id:'simklpicks.recommended-series', name:'Simkl Picks • Series' },
        { type:'series', id:'simklpicks.recommended-anime', name:'Simkl Picks • Anime' }
      ]
    });
  }

  return sendJSON(res, { error:'not found' }, 404);
});

server.listen(PORT, ()=> {
  console.log(`[SimklPicks OAuth UI] listening on :${PORT}`);
  console.log(`[SimklPicks OAuth UI] Visit /setup to authorize SIMKL`);
});
EOF

CMD ["npm","start"]
