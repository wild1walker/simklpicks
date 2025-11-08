FROM node:20-alpine
WORKDIR /app

# Minimal package
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "4.0.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src
ENV PORT=7769
EXPOSE 7769

# -----------------------
# src/simkl.js
# -----------------------
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
  // Build a light profile (genres + weights) for AI prompt
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

# -----------------------
# src/ai.js  (OpenRouter)
# -----------------------
RUN cat > src/ai.js <<'EOF'
import fetch from 'node-fetch';

// returns [{title, year?, kind}] where kind in {"movie","series","anime"}
export async function aiSuggest(profileMovies, profileSeries, max=80){
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) return [];
  const model = process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet';
  const sys = `Output ONLY a JSON array. Each item: {"title":string,"year":number|undefined,"kind":"movie"|"series"|"anime"}.
Rules: suggest NEW-to-user titles (assume anything supplied is already seen), slightly niche but likely to be enjoyed, cover movies/series/anime where applicable. No commentary.`;
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

# -----------------------
# src/tvdb.js  (robust resolver)
# -----------------------
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
  const j = await r.json().catch(()=>null);
  TVDB_TOKEN = j?.data?.token || null;
  TVDB_EXP = Date.now() + 24*3600*1000; // 1 day
}
async function H() {
  if (!TVDB_TOKEN || Date.now() > TVDB_EXP) await tvdbLogin();
  return { 'Authorization': `Bearer ${TVDB_TOKEN}`, 'Content-Type':'application/json' };
}
async function jget(path) {
  const r = await fetch(`${API}${path}`, { headers: await H() });
  if (!r.ok) throw new Error(`TVDB ${r.status} ${r.statusText} ${path}`);
  return r.json().catch(()=>({}));
}
function cleanTitle(s){
  if (!s) return '';
  let t = String(s);
  t = t.replace(/\(\d{4}\)/g, ' ');
  t = t.split(' - ')[0];
  t = t.split(': ')[0];
  t = t.replace(/[^\p{L}\p{N}\s]/gu,' ').replace(/\s+/g,' ').trim();
  return t;
}
function yInt(y){ const n=Number(y); return Number.isFinite(n)&&n>1800&&n<3000?n:undefined; }
function matchYearScore(entry, year){
  if (!year) return 0.5;
  const y = yInt(year); if (!y) return 0.0;
  const c1 = yInt(entry?.year);
  const c2 = entry?.firstAired ? yInt(String(entry.firstAired).slice(0,4)) : undefined;
  if (c1===y || c2===y) return 1.0;
  if ([y-1,y+1].includes(c1) || [y-1,y+1].includes(c2)) return 0.6;
  return 0.0;
}
function pickBest(arr, title, year){
  if (!Array.isArray(arr)||!arr.length) return null;
  const q = cleanTitle(title);
  const scored = arr.map(x=>{
    const name = String(x?.name || x?.title || '').trim();
    const m = cleanTitle(name);
    const titleSim = (q && m) ? (q.toLowerCase()===m.toLowerCase()?1:0) : 0;
    const yScore = matchYearScore(x, year);
    const pop = Number(x?.siteRatingCount || x?.score || 0);
    return { x, score: titleSim*2 + yScore + (pop/1000) };
  }).sort((a,b)=> b.score-a.score);
  return scored[0].x;
}
async function search(title, year, type){ // type: 'movie'|'series'|undefined
  const q = new URLSearchParams({ query: title, ...(type?{type}:{}) }).toString();
  const j = await jget(`/search?${q}`).catch(()=>null);
  let arr = j?.data || [];
  if (year) {
    const y = yInt(year);
    if (y) arr = arr.filter(x=>{
      const y1 = yInt(x?.year);
      const y2 = x?.firstAired ? yInt(String(x.firstAired).slice(0,4)) : undefined;
      return (y1===y||y2===y||y1===y-1||y1===y+1||y2===y-1||y2===y+1);
    });
  }
  return arr;
}
export async function toTvdbId(kind, title, year){
  const t = (kind==='movie')?'movie':'series';
  const tries = [
    [title, year, t],
    [title, undefined, t],
    [cleanTitle(title), year, t],
    [title, year, undefined],
    [cleanTitle(title), undefined, undefined]
  ];
  for (const [ti, yr, ty] of tries){
    if (!ti) continue;
    const arr = await search(ti, yr, ty).catch(()=>[]);
    const best = pickBest(arr, ti, yr);
    if (best?.tvdb_id || best?.id){
      const id = best.tvdb_id ?? best.id;
      return `tvdb:${id}`;
    }
  }
  return null;
}
EOF

# -----------------------
# src/index.js (server)
# -----------------------
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { buckets, profileFrom } from './simkl.js';
import { aiSuggest } from './ai.js';
import { toTvdbId } from './tvdb.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL  = Number(process.env.CACHE_TTL_MINUTES || 240) * 60 * 1000;

const MANIFEST = {
  id: 'org.simkl.picks',
  version: '4.0.0',
  name: 'SimklPicks (AI-only, TVDB)',
  description: 'AI-only novel recommendations from Simkl history & ratings; metadata via tvdb: IDs.',
  resources: ['catalog'],
  types: ['movie','series'],   // anime is served as "series"
  idPrefixes: ['tvdb'],
  catalogs: [
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Movies (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Series (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Anime (AI, unseen)' }
  ]
};

function sendJSON(res, obj, code=200){
  res.writeHead(code, {
    'Content-Type':'application/json; charset=utf-8',
    'Access-Control-Allow-Origin':'*',
    'Cache-Control':'no-store'
  });
  res.end(JSON.stringify(obj));
}
function alwaysMetas(res, fn){
  (async ()=>{ const metas = await fn(); sendJSON(res, { metas }); })()
    .catch(()=> sendJSON(res, { metas: [] }));
}

const cache = new Map(); // path -> {data, exp}

async function build(kind){
  // 1) Build profiles for AI
  const bMovie  = await buckets('movie').catch(()=>({history:[],ratings:[]}));
  const bSeries = await buckets('series').catch(()=>({history:[],ratings:[]}));
  const profMovies = profileFrom(bMovie);
  const profSeries = profileFrom(bSeries);

  // 2) Ask AI for novel picks (AI-only; no fallback)
  const suggestions = await aiSuggest(profMovies, profSeries, 90); // [{title, year, kind}]
  if (!Array.isArray(suggestions) || suggestions.length === 0) return []; // AI empty => empty catalog

  // 3) Keep only target kind (anime -> series)
  const wanted = suggestions.filter(s => {
    const k = (s.kind === 'anime') ? 'series' : s.kind;
    return k === kind;
  });
  if (wanted.length === 0) return [];

  // 4) Resolve to TVDB IDs
  const items = [];
  for (const s of wanted) {
    const tvdb = await toTvdbId(kind, s.title, s.year).catch(()=>null);
    if (tvdb) items.push({ id: tvdb, type: kind, name: s.title, year: s.year });
    if (items.length >= 50) break;
  }
  return items;
}

const server = http.createServer((req,res)=>{
  const u = new URL(req.url, `http://${req.headers.host}`);
  const rawPath = u.pathname;
  const path = rawPath.replace(/\.json$/i,''); // strip .json suffix for routing

  if (path==='/' || path==='/health') return res.end('ok');
  if (rawPath==='/manifest.json' || path==='/manifest') return sendJSON(res, MANIFEST);

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

  // Raw AI output (exact items from OpenRouter)
  if (path==='/ai-raw'){
    (async ()=>{
      const bMovie  = await buckets('movie').catch(()=>({history:[],ratings:[]}));
      const bSeries = await buckets('series').catch(()=>({history:[],ratings:[]}));
      const out = await aiSuggest(profileFrom(bMovie), profileFrom(bSeries), 90).catch(()=>[]);
      return sendJSON(res, { items: out });
    })().catch(()=> sendJSON(res,{ items: [], error:'ai error' }));
    return;
  }

  // Preview after filtering by type, before TVDB resolution
  if (path==='/ids-preview'){
    (async ()=>{
      const type = (u.searchParams.get('type')||'movie').toLowerCase(); // movie|series|anime
      const bMovie  = await buckets('movie').catch(()=>({history:[],ratings:[]}));
      const bSeries = await buckets('series').catch(()=>({history:[],ratings:[]}));
      const raw = await aiSuggest(profileFrom(bMovie), profileFrom(bSeries), 90).catch(()=>[]);
      const target = type==='anime' ? 'anime' : type;
      const items = raw.filter(x=>{
        const k = (x.kind==='anime')?'anime':(x.kind==='series'?'series':'movie');
        return k===target;
      }).map(x=>({ title:x.title, year:x.year, kind:x.kind }));
      return sendJSON(res, { type, items });
    })().catch(()=> sendJSON(res,{ type:'unknown', items:[] }));
    return;
  }

  // TVDB single-title debug
  if (path==='/tvdb-lookup'){
    (async ()=>{
      const title = u.searchParams.get('title') || '';
      const year  = u.searchParams.get('year') || '';
      const kind  = (u.searchParams.get('kind') || 'movie').toLowerCase(); // movie|series|anime
      const k = (kind==='anime') ? 'series' : kind;
      const id = await toTvdbId(k, title, year).catch(()=>null);
      return sendJSON(res, { title, year, kind, tvdb: id });
    })().catch(()=> sendJSON(res,{ error:'lookup failed' }));
    return;
  }

  // Stremio catalogs
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
      return alwaysMetas(res, async ()=>{
        const metas = await build(kind);
        cache.set(p, { data: metas, exp: Date.now() + TTL });
        return metas;
      });
    }
  }

  return sendJSON(res, { error:'not found' }, 404);
});

server.listen(PORT, ()=>{
  console.log(`[SimklPicks AI-only] listening on :${PORT}`);
  console.log(`[SimklPicks AI-only] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

CMD ["npm","start"]
