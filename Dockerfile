FROM node:20-alpine
WORKDIR /app

# ---- minimal package.json ----
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "5.1.0",
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
# Default FREE model on OpenRouter; can override in Koyeb
ENV LLM_MODEL=meta-llama/llama-3.3-8b-instruct:free
EXPOSE 7769

# -----------------------
# src/simkl.js
# -----------------------
RUN cat > src/simkl.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api.simkl.com';

function simklHeaders() {
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
  const r = await fetch(url, { headers: simklHeaders() });
  if (!r.ok) throw new Error(`SIMKL ${r.status} ${r.statusText} ${path}`);
  return r.json();
}

export async function getUserSettings() { return jget('/users/settings'); }
export async function getHistory(kind, page=1, limit=100) { return jget(`/sync/history/${kind}`, { page, limit }); }
export async function getRatings(kind) { return jget(`/sync/ratings/${kind}`); }

function baseOf(x){ return x?.movie || x?.show || x?.anime || x || {}; }

export function profileFromHistoryAndRatings({ history=[], ratings=[] }) {
  const bag = new Map();
  const add = (g,w)=> bag.set(g, (bag.get(g)||0) + w);
  const mix = [...history, ...ratings];
  for (const x of mix) {
    const b = baseOf(x);
    const gs = b.genres || b.genre || [];
    const w = x?.rating ? (Number(x.rating) || 1) : (x?.watched_at ? 1.0 : 0.5);
    for (const g of gs) if (g) add(String(g).toLowerCase(), w);
  }
  return { genres: Array.from(bag.entries()).map(([name,weight])=>({name,weight})) };
}

export async function makeProfiles() {
  const [hM,hS,hA] = await Promise.all([
    getHistory('movies',1,100).catch(()=>[]),
    getHistory('shows',1,100).catch(()=>[]),
    getHistory('anime',1,100).catch(()=>[])
  ]);
  const [rM,rS,rA] = await Promise.all([
    getRatings('movies').catch(()=>[]),
    getRatings('shows').catch(()=>[]),
    getRatings('anime').catch(()=>[])
  ]);
  const M = { history: Array.isArray(hM)?hM:(hM?.items||[]), ratings: Array.isArray(rM)?rM:(rM?.items||[]) };
  const S = { history: Array.isArray(hS)?hS:(hS?.items||[]), ratings: Array.isArray(rS)?rS:(rS?.items||[]) };
  const A = { history: Array.isArray(hA)?hA:(hA?.items||[]), ratings: Array.isArray(rA)?rA:(rA?.items||[]) };
  return {
    movies: profileFromHistoryAndRatings(M),
    series: profileFromHistoryAndRatings(S),
    anime:  profileFromHistoryAndRatings(A),
    counts: {
      movies:{history:M.history.length,ratings:M.ratings.length},
      series:{history:S.history.length,ratings:S.ratings.length},
      anime: {history:A.history.length,ratings:A.ratings.length}
    }
  };
}
EOF

# -----------------------
# src/ai.js
# -----------------------
RUN cat > src/ai.js <<'EOF'
import fetch from 'node-fetch';

function normalizeModel(m){
  let model = (m||'').trim();
  if (!model) return 'meta-llama/llama-3.3-8b-instruct:free';
  if (model.toLowerCase().startsWith('openrouter/')) model = model.slice('openrouter/'.length);
  if (model.toLowerCase() === 'openrouter') model = 'meta-llama/llama-3.3-8b-instruct:free';
  return model;
}

export async function aiSuggest(profile, max=90){
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) return [];
  const model = normalizeModel(process.env.LLM_MODEL);
  const site = process.env.OPENROUTER_SITE_URL || process.env.SELF_BASE_URL || '';
  const app  = process.env.OPENROUTER_APP_NAME || 'SimklPicks';

  const sys = `You are a recommender. Output ONLY a JSON array.
Each item: {"title":string,"year":number|undefined,"kind":"movie"|"series"|"anime"}.
Suggest NEW-to-user titles (assume profiles are watched/liked), slightly niche, diverse mix.
No commentary; JSON array only.`;

  const user = { max, profile };
  const body = {
    model,
    temperature: 0.4,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: sys },
      { role: 'user', content: JSON.stringify(user) }
    ]
  };

  const headers = { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json' };
  if (site) headers['HTTP-Referer'] = site;
  headers['X-Title'] = app;

  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', { method:'POST', headers, body: JSON.stringify(body) });
  const text = await r.text();
  let j; try { j = JSON.parse(text); } catch { j = null; }
  globalThis.__AI_LAST_RAW__ = { status:r.status, ok:r.ok, text, parsed:j, model };
  if (!r.ok) return [];
  const content = j?.choices?.[0]?.message?.content || '[]';
  try {
    const parsed = JSON.parse(content);
    const arr = Array.isArray(parsed) ? parsed : (Array.isArray(parsed.items) ? parsed.items : []);
    return arr.map(x => ({
      title: String(x?.title||'').trim(),
      year: (x?.year!=null ? Number(x.year) || undefined : undefined),
      kind: (x?.kind==='anime'?'anime':(x?.kind==='series'?'series':'movie'))
    })).filter(x=>x.title);
  } catch { return []; }
}

export function getLastAiRaw(){ return globalThis.__AI_LAST_RAW__ || null; }
EOF

# -----------------------
# src/tvdb.js
# -----------------------
RUN cat > src/tvdb.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api4.thetvdb.com/v4';

let TVDB_TOKEN=null, TVDB_EXP=0;
async function tvdbLogin(){
  const apikey = process.env.TVDB_API_KEY || '';
  const pin = process.env.TVDB_PIN || '';
  const body = pin ? {apikey,pin}:{apikey};
  const r = await fetch(`${API}/login`, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`TVDB login ${r.status}`);
  const j = await r.json().catch(()=>null);
  TVDB_TOKEN = j?.data?.token || null; TVDB_EXP = Date.now() + 24*3600*1000;
}
async function H(){ if (!TVDB_TOKEN||Date.now()>TVDB_EXP) await tvdbLogin(); return {'Authorization':`Bearer ${TVDB_TOKEN}`,'Content-Type':'application/json'}; }
async function jget(path){ const r = await fetch(`${API}${path}`, { headers: await H() }); if (!r.ok) throw new Error(`TVDB ${r.status} ${path}`); return r.json().catch(()=>({})); }

function cleanTitle(s){ if(!s) return ''; let t=String(s); t=t.replace(/\(\d{4}\)/g,' '); t=t.split(' - ')[0]; t=t.split(': ')[0]; t=t.replace(/[^\p{L}\p{N}\s]/gu,' ').replace(/\s+/g,' ').trim(); return t; }
function yInt(y){ const n=Number(y); return Number.isFinite(n)&&n>1800&&n<3000?n:undefined; }
function matchYearScore(entry,year){ if(!year) return 0.5; const y=yInt(year); if(!y) return 0.0; const c1=yInt(entry?.year); const c2=entry?.firstAired?yInt(String(entry.firstAired).slice(0,4)):undefined; if(c1===y||c2===y) return 1.0; if([y-1,y+1].includes(c1)||[y-1,y+1].includes(c2)) return 0.6; return 0.0; }
function pickBest(arr,title,year){ if(!Array.isArray(arr)||!arr.length) return null; const q=cleanTitle(title); const scored=arr.map(x=>{ const name=String(x?.name||x?.title||'').trim(); const m=cleanTitle(name); const titleSim=(q&&m)?(q.toLowerCase()===m.toLowerCase()?1:0):0; const yScore=matchYearScore(x,year); const pop=Number(x?.siteRatingCount||x?.score||0); return {x,score:titleSim*2+yScore+(pop/1000)}; }).sort((a,b)=>b.score-a.score); return scored[0].x; }
async function search(title,year,type){ const q=new URLSearchParams({query:title,...(type?{type}:{})}).toString(); const j=await jget(`/search?${q}`).catch(()=>null); let arr=j?.data||[]; if(year){ const y=yInt(year); if(y) arr=arr.filter(x=>{ const y1=yInt(x?.year); const y2=x?.firstAired?yInt(String(x.firstAired).slice(0,4)):undefined; return (y1===y||y2===y||y1===y-1||y1===y+1||y2===y-1||y2===y+1);}); } return arr; }

export async function toTvdbId(kind,title,year){
  const t=(kind==='movie')?'movie':'series';
  const tries=[[title,year,t],[title,undefined,t],[cleanTitle(title),year,t],[title,year,undefined],[cleanTitle(title),undefined,undefined]];
  for (const [ti,yr,ty] of tries){ if(!ti) continue; const arr=await search(ti,yr,ty).catch(()=>[]); const best=pickBest(arr,ti,yr); if(best?.tvdb_id||best?.id){ const id=best.tvdb_id??best.id; return `tvdb:${id}`; } }
  return null;
}
EOF

# -----------------------
# src/index.js (server)
# -----------------------
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { makeProfiles, getHistory, getRatings } from './simkl.js';
import { aiSuggest, getLastAiRaw } from './ai.js';
import { toTvdbId } from './tvdb.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL  = Number(process.env.CACHE_TTL_MINUTES || 240) * 60 * 1000;

const MANIFEST = {
  id: 'org.simkl.picks',
  version: '5.1.0',
  name: 'SimklPicks (AI-only, TVDB)',
  description: 'AI-only novel recommendations from Simkl watch history & ratings; metadata via TVDB.',
  resources: ['catalog'],
  types: ['movie','series'],   // anime served as series
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
  const profiles = await makeProfiles().catch(()=>null);
  if (!profiles) return [];
  const items = await aiSuggest(profiles, 90).catch(()=>[]);
  if (!Array.isArray(items) || items.length === 0) return [];
  const wanted = items.filter(s => {
    const k = (s.kind === 'anime') ? 'series' : s.kind;
    return k === kind;
  });
  if (wanted.length === 0) return [];
  const metas = [];
  for (const s of wanted) {
    const id = await toTvdbId(kind, s.title, s.year).catch(()=>null);
    if (id) metas.push({ id, type: kind, name: s.title, year: s.year });
    if (metas.length >= 50) break;
  }
  return metas;
}

const server = http.createServer((req,res)=>{
  const u = new URL(req.url, `http://${req.headers.host}`);
  const rawPath = u.pathname;
  const path = rawPath.replace(/\.json$/i,''); // support .json suffix

  if (path==='/' || path==='/health') return res.end('ok');
  if (rawPath==='/manifest.json' || path==='/manifest') return sendJSON(res, MANIFEST);

  // Debug: env
  if (path==='/env-check'){
    return sendJSON(res, {
      ok:true,
      simklApi: !!process.env.SIMKL_API_KEY,
      simklTok: !!process.env.SIMKL_ACCESS_TOKEN,
      simklBearer: process.env.SIMKL_BEARER === '1',
      tvdbKey: !!process.env.TVDB_API_KEY,
      tvdbPin: !!process.env.TVDB_PIN || false,
      aiEnabled: !!process.env.OPENROUTER_API_KEY,
      model: process.env.LLM_MODEL || 'meta-llama/llama-3.3-8b-instruct:free'
    });
  }

  // Simkl quick stats
  if (path==='/simkl-stats'){
    (async ()=>{
      const p = await makeProfiles().catch(()=>null);
      return sendJSON(res, p ? p.counts :
        { movies:{history:0,ratings:0}, series:{history:0,ratings:0}, anime:{history:0,ratings:0} });
    })().catch(()=> sendJSON(res, { movies:{history:0,ratings:0}, series:{history:0,ratings:0}, anime:{history:0,ratings:0} }));
    return;
  }

  // Simkl raw
  if (path==='/simkl-history'){
    (async ()=>{
      const [m,s,a] = await Promise.all([
        getHistory('movies',1,50).catch(()=>[]),
        getHistory('shows',1,50).catch(()=>[]),
        getHistory('anime',1,50).catch(()=>[])
      ]);
      return sendJSON(res, { movies: m, shows: s, anime: a });
    })().catch(()=> sendJSON(res, { movies:[], shows:[], anime:[] }));
    return;
  }
  if (path==='/simkl-ratings'){
    (async ()=>{
      const [m,s,a] = await Promise.all([
        getRatings('movies').catch(()=>[]),
        getRatings('shows').catch(()=>[]),
        getRatings('anime').catch(()=>[])
      ]);
      return sendJSON(res, { movies: m, shows: s, anime: a });
    })().catch(()=> sendJSON(res, { movies:[], shows:[], anime:[] }));
    return;
  }

  // AI
  if (path==='/ai-raw'){
    (async ()=>{
      const profiles = await makeProfiles().catch(()=>null);
      if (!profiles) return sendJSON(res, { type:'mixed', items: [] });
      const out = await aiSuggest(profiles, 90).catch(()=>[]);
      return sendJSON(res, { type: 'mixed', items: out });
    })().catch(()=> sendJSON(res, { type:'mixed', items: [], error:'ai error' }));
    return;
  }
  if (path==='/ai-debug'){
    const payload = getLastAiRaw();
    return sendJSON(res, payload ? payload : { ok:false, note:'call /ai-raw once first' });
  }

  // Preview titles (pre-TVDB), by type
  if (path==='/ids-preview'){
    (async ()=>{
      const type = (u.searchParams.get('type')||'movie').toLowerCase(); // movie|series|anime
      const profiles = await makeProfiles().catch(()=>null);
      if (!profiles) return sendJSON(res,{ type, items:[] });
      const raw = await aiSuggest(profiles, 90).catch(()=>[]);
      const target = type==='anime' ? 'anime' : type;
      const items = raw.filter(x=>{
        const k = (x.kind==='anime')?'anime':(x.kind==='series'?'series':'movie');
        return k===target;
      }).map(x=>({ title:x.title, year:x.year, kind:x.kind }));
      return sendJSON(res, { type, items });
    })().catch(()=> sendJSON(res,{ type:'unknown', items:[] }));
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
