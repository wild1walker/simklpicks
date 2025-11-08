FROM node:20-alpine
WORKDIR /app

# minimal package.json
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "3.1.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src
ENV PORT=7769
EXPOSE 7769

# =========================
#  src/simkl.js
# =========================
RUN cat > src/simkl.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api.simkl.com';
const ext = { extended: 'full' };

function H() {
  const h = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'simkl-api-key': process.env.SIMKL_API_KEY || ''
  };
  const tok = process.env.SIMKL_ACCESS_TOKEN || '';
  if (tok) h['Authorization'] = (process.env.SIMKL_BEARER === '1') ? `Bearer ${tok}` : tok;
  return h;
}
async function jget(path, q = {}) {
  const qs = new URLSearchParams(q).toString();
  const url = API + path + (qs ? `?${qs}` : '');
  const r = await fetch(url, { headers: H() });
  if (!r.ok) throw new Error(`SIMKL ${r.status} ${r.statusText} ${path}`);
  return r.json();
}
export function baseOf(x){ return x?.movie || x?.show || x || {}; }

export async function buckets(kind){ // 'movie' | 'series'
  const type = kind === 'movie' ? 'movies' : 'shows';
  const [history, ratings] = await Promise.all([
    jget(`/sync/history/${type}`, ext).catch(()=>[]),
    jget(`/sync/ratings/${type}`, ext).catch(()=>[])
  ]);
  return {history, ratings};
}
export function profileFrom({history=[],ratings=[]}){
  const bag = new Map();
  const add = (g,w)=> bag.set(g,(bag.get(g)||0)+w);
  const mix = [...history, ...ratings];
  for (const x of mix){
    const b = baseOf(x);
    const gs = b.genres || b.genre || [];
    const w  = x?.rating ? (Number(x.rating)||1) : (x?.watched_at ? 1.0 : 0.5);
    for (const g of gs) if (g) add(String(g).toLowerCase(), w);
  }
  const genres = Array.from(bag.entries()).map(([name,weight])=>({name,weight}));
  return { genres };
}
EOF

# =========================
#  src/ai.js (OpenRouter optional)
# =========================
RUN cat > src/ai.js <<'EOF'
import fetch from 'node-fetch';

// returns [{title, year?, kind}] where kind in {"movie","series","anime"}
export async function aiSuggest(profileMovies, profileSeries, max=80){
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) return [];
  const model = process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet';
  const sys = `Output ONLY JSON array. Each item: {"title":string,"year":number|undefined,"kind":"movie"|"series"|"anime"}.
Suggest new-to-user, slightly niche picks likely to be enjoyed, based on the two profiles. No commentary.`;
  const user = { max, profileMovies, profileSeries };

  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model, temperature: 0.4, response_format: { type: 'json_object' },
      messages: [{role:'system',content:sys},{role:'user',content:JSON.stringify(user)}]
    })
  });
  const j = await r.json().catch(()=>null);
  const content = j?.choices?.[0]?.message?.content || '[]';
  try {
    const parsed = JSON.parse(content);
    const arr = Array.isArray(parsed) ? parsed : (Array.isArray(parsed.items) ? parsed.items : []);
    return arr.map(x=>({
      title: String(x?.title||'').trim(),
      year: (x?.year!=null ? Number(x.year) || undefined : undefined),
      kind: (x?.kind==='anime'?'anime':(x?.kind==='series'?'series':'movie'))
    })).filter(x=>x.title);
  } catch { return []; }
}
EOF

# =========================
#  src/tvdb.js  (resolve to TVDB IDs)
# =========================
RUN cat > src/tvdb.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api4.thetvdb.com/v4';

let TVDB_TOKEN = null;
let TVDB_EXP = 0;

async function tvdbLogin() {
  const apikey = process.env.TVDB_API_KEY || '';
  const pin = process.env.TVDB_PIN || '';
  const body = pin ? { apikey, pin } : { apikey };
  const r = await fetch(`${API}/login`, {
    method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify(body)
  });
  if (!r.ok) throw new Error(`TVDB login ${r.status}`);
  const j = await r.json();
  TVDB_TOKEN = j?.data?.token || null;
  // token typically valid for a while; set soft TTL (1 day)
  TVDB_EXP = Date.now() + 24*3600*1000;
}

async function H() {
  if (!TVDB_TOKEN || Date.now() > TVDB_EXP) await tvdbLogin();
  return { 'Authorization': `Bearer ${TVDB_TOKEN}`, 'Content-Type':'application/json' };
}

async function jget(path) {
  const r = await fetch(`${API}${path}`, { headers: await H() });
  if (!r.ok) throw new Error(`TVDB ${r.status} ${r.statusText} ${path}`);
  return r.json();
}

// --- Search helpers ---
// TV: /search?query=...&type=series
// Movie: /search?query=...&type=movie
export async function tvdbSearchSeries(title, year){
  const q = new URLSearchParams({ query: title, type: 'series' });
  const j = await jget(`/search?${q.toString()}`).catch(()=>null);
  let arr = j?.data || [];
  if (year) arr = arr.filter(x => Number(x?.year) === Number(year) || Number(x?.firstAired?.slice(0,4))===Number(year));
  return arr;
}
export async function tvdbSearchMovie(title, year){
  const q = new URLSearchParams({ query: title, type: 'movie' });
  const j = await jget(`/search?${q.toString()}`).catch(()=>null);
  let arr = j?.data || [];
  if (year) arr = arr.filter(x => Number(x?.year) === Number(year) || Number(x?.firstAired?.slice(0,4))===Number(year));
  return arr;
}

function pickBest(arr){
  if (!Array.isArray(arr) || !arr.length) return null;
  // prefer highest score if present, else popularity proxies
  const ranked = arr.slice().sort((a,b)=>{
    const sa = Number(a?.score||0), sb = Number(b?.score||0);
    if (sb!==sa) return sb-sa;
    const va = Number(a?.siteRatingCount||0), vb = Number(b?.siteRatingCount||0);
    if (vb!==va) return vb-va;
    return String(a?.name||'').localeCompare(String(b?.name||''));
  });
  return ranked[0];
}

export async function toTvdbId(kind, title, year){
  const results = (kind==='movie') ? await tvdbSearchMovie(title, year)
                                   : await tvdbSearchSeries(title, year);
  const best = pickBest(results);
  return best?.tvdb_id ? `tvdb:${best.tvdb_id}` :
         best?.id      ? `tvdb:${best.id}` : null;
}
EOF

# =========================
#  src/index.js (server)
# =========================
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { buckets, profileFrom } from './simkl.js';
import { aiSuggest } from './ai.js';
import { toTvdbId } from './tvdb.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL = Number(process.env.CACHE_TTL_MINUTES || 240) * 60 * 1000;

const MANIFEST = {
  id: 'org.simkl.picks',
  version: '3.1.0',
  name: 'SimklPicks (AI + TVDB)',
  description: 'AI suggestions from Simkl history/ratings; all metadata via TVDB (tvdb: IDs).',
  resources: ['catalog'],
  types: ['movie','series'],   // anime is served as type "series"
  idPrefixes: ['tvdb'],
  catalogs: [
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Movies (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Series (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Anime (AI, unseen)' }
  ]
};

function sendJSON(res, obj, code=200){
  res.writeHead(code, {'Content-Type':'application/json; charset=utf-8','Access-Control-Allow-Origin':'*','Cache-Control':'no-store'});
  res.end(JSON.stringify(obj));
}

function ensureMetas(res, fn){
  (async ()=>{ const metas = await fn(); sendJSON(res, { metas }); })()
    .catch(()=> sendJSON(res, { metas: [] }));
}

const cache = new Map(); // kind -> {data, exp}

async function build(kind){
  // 1) build profiles from Simkl
  const bMovie  = await buckets('movie').catch(()=>({history:[],ratings:[]}));
  const bSeries = await buckets('series').catch(()=>({history:[],ratings:[]}));
  const profMovies = profileFrom(bMovie);
  const profSeries = profileFrom(bSeries);

  // 2) ask AI for fresh suggestions (or empty if no OPENROUTER_API_KEY)
  const suggestions = await aiSuggest(profMovies, profSeries, 90); // [{title,year,kind}]

  // 3) map suggestions to TVDB IDs
  const items = [];
  for (const s of suggestions){
    const targetKind = (s.kind === 'anime') ? 'series' : s.kind; // anime resolves as series in Stremio
    if (targetKind !== kind) continue;
    const id = await toTvdbId(targetKind, s.title, s.year).catch(()=>null);
    if (id) items.push({ id, type: targetKind, name: s.title, year: s.year });
    if (items.length >= 50) break;
  }
  return items;
}

http.createServer((req,res)=>{
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname.replace(/\.json$/i,'');
  if (path==='/' || path==='/health') return res.end('ok');
  if (path==='/manifest.json') return sendJSON(res, MANIFEST);

  if (path==='/env-check'){
    return sendJSON(res, {
      ok:true,
      simklApi: !!process.env.SIMKL_API_KEY,
      simklTok: !!process.env.SIMKL_ACCESS_TOKEN,
      tvdbKey: !!process.env.TVDB_API_KEY,
      tvdbPin: !!process.env.TVDB_PIN || false,
      aiEnabled: !!process.env.OPENROUTER_API_KEY
    });
  }

  const routes = [
    ['/stremio/v1/catalog/movie/simklpicks.recommended-movies',  'movie'],
    ['/stremio/v1/catalog/series/simklpicks.recommended-series', 'series'],
    ['/stremio/v1/catalog/series/simklpicks.recommended-anime',  'series'],
    ['/catalog/movie/simklpicks.recommended-movies',             'movie'],
    ['/catalog/series/simklpicks.recommended-series',            'series'],
    ['/catalog/series/simklpicks.recommended-anime',             'series']
  ];

  for (const [p, kind] of routes){
    if (path === p){
      const C = cache.get(p);
      if (C && Date.now() <= C.exp) return sendJSON(res, { metas: C.data });
      return ensureMetas(res, async ()=>{
        const metas = await build(kind);
        cache.set(p, { data: metas, exp: Date.now() + TTL });
        return metas;
      });
    }
  }

  // debug: preview raw titles resolved to TVDB ids
  if (path==='/ids-preview'){
    return (async ()=>{
      const k = (url.searchParams.get('type')||'movie').toLowerCase();
      const bMovie  = await buckets('movie').catch(()=>({history:[],ratings:[]}));
      const bSeries = await buckets('series').catch(()=>({history:[],ratings:[]}));
      const profMovies = profileFrom(bMovie);
      const profSeries = profileFrom(bSeries);
      const sugg = await aiSuggest(profMovies, profSeries, 30);
      const out = [];
      for (const s of sugg){
        const targetKind = (s.kind==='anime') ? 'series' : s.kind;
        if (targetKind !== k) continue;
        const id = await toTvdbId(targetKind, s.title, s.year).catch(()=>null);
        out.push({ title:s.title, year:s.year, kind:s.kind, tvdb:id });
      }
      return sendJSON(res, { type:k, items: out });
    })().catch(()=> sendJSON(res,{type:'unknown',items:[]}));
  }

  // fallback
  return sendJSON(res, { error: 'not found' }, 404);
}).listen(PORT, ()=> {
  console.log(`[SimklPicks TVDB] listening on :${PORT}`);
  console.log(`[SimklPicks TVDB] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

CMD ["npm","start"]
