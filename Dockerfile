FROM node:20-alpine
WORKDIR /app

# --- Minimal package.json ---
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "2.5.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# =========================
#  simklClient.js
# =========================
RUN cat > src/simklClient.js <<'EOF'
import fetch from 'node-fetch';
const API = 'https://api.simkl.com';

function H() {
  const h = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'simkl-api-key': process.env.SIMKL_API_KEY || ''
  };
  const tok = process.env.SIMKL_ACCESS_TOKEN || '';
  if (tok) {
    // Set SIMKL_BEARER=1 if your token requires "Bearer <token>"
    h['Authorization'] = (process.env.SIMKL_BEARER === '1') ? `Bearer ${tok}` : tok;
  }
  return h;
}
async function jget(path, q = {}) {
  const qs = new URLSearchParams(q).toString();
  const url = API + path + (qs ? `?${qs}` : '');
  const r = await fetch(url, { headers: H() });
  const t = await r.text();
  let body = t ? (()=>{ try { return JSON.parse(t); } catch { return { raw: t }; } })() : null;
  if (!r.ok) throw new Error(`${r.status} ${r.statusText} ${path}`);
  return body;
}
const ext = { extended: 'full' };

export async function userMovies(){ 
  const [history,ratings,watchlist] = await Promise.all([
    jget('/sync/history/movies', ext).catch(()=>[]),
    jget('/sync/ratings/movies', ext).catch(()=>[]),
    jget('/sync/watchlist/movies', ext).catch(()=>[])
  ]);
  return {history,ratings,watchlist};
}
export async function userShows(){
  const [history,ratings,watchlist] = await Promise.all([
    jget('/sync/history/shows', ext).catch(()=>[]),
    jget('/sync/ratings/shows', ext).catch(()=>[]),
    jget('/sync/watchlist/shows', ext).catch(()=>[])
  ]);
  return {history,ratings,watchlist};
}
export async function userAnime(){ // anime uses shows buckets
  const [history,ratings,watchlist] = await Promise.all([
    jget('/sync/history/shows', ext).catch(()=>[]),
    jget('/sync/ratings/shows', ext).catch(()=>[]),
    jget('/sync/watchlist/shows', ext).catch(()=>[])
  ]);
  return {history,ratings,watchlist};
}

export function baseFromItem(x){ return x?.movie || x?.show || x || {}; }
export function simklIdOf(x){
  const b = baseFromItem(x);
  return b?.ids?.simkl ?? b?.simkl_id ?? b?.id ?? null;
}

// details (to fetch external IDs)
export async function detailsMovie(simklId){ return jget(`/movies/${simklId}`, ext); }
export async function detailsShow(simklId){  return jget(`/shows/${simklId}`,  ext); }

// wide pools (graceful on 404)
async function tryList(path){ try { return await jget(path, ext); } catch { return []; } }
export async function poolMoviesWide() {
  const lists = await Promise.all([
    tryList('/movies/top'),
    tryList('/movies/popular'),
    tryList('/movies/trending')
  ]);
  return lists.flat().filter(Boolean);
}
export async function poolShowsWide() {
  const lists = await Promise.all([
    tryList('/shows/top'),
    tryList('/shows/popular'),
    tryList('/shows/trending')
  ]);
  return lists.flat().filter(Boolean);
}

// profile from history+ratings (not watchlist)
function genreBagFrom(items) {
  const bag = new Map();
  const add = (g, w=1)=> bag.set(g, (bag.get(g)||0)+w);
  for (const x of items || []) {
    const b = baseFromItem(x);
    const gs = b.genres || b.genre || [];
    const weight = x?.rating ? (Number(x.rating)||1) : (x?.watched_at ? 1.0 : 0.5);
    for (const g of gs) if (g) add(String(g).toLowerCase(), weight);
  }
  return bag;
}
function scoreByGenres(item, bag) {
  const b = baseFromItem(item);
  const gs = b.genres || b.genre || [];
  let s = 0;
  for (const g of gs) s += bag.get(String(g||'').toLowerCase()) || 0;
  const yr = Number(b.year || b.first_aired || 0);
  if (yr) s += Math.max(0, (yr - 1990)) * 0.01;
  return s;
}
export async function buildProfile(kind) {
  const buckets = (kind === 'movie') ? await userMovies() : await userShows();
  const base = [].concat(buckets.history || []).concat(buckets.ratings || []);
  return genreBagFrom(base);
}

// personalized (non-AI) candidates
export async function candidatesMoviesPersonalized() {
  const pool = await poolMoviesWide();
  const bag  = await buildProfile('movie');
  return pool.map(it => ({ it, s: scoreByGenres(it, bag) }))
             .sort((a,b) => b.s - a.s)
             .map(x => x.it);
}
export async function candidatesShowsPersonalized() {
  const pool = await poolShowsWide();
  const bag  = await buildProfile('series');
  return pool.map(it => ({ it, s: scoreByGenres(it, bag) }))
             .sort((a,b) => b.s - a.s)
             .map(x => x.it);
}
export async function filterAnimeFromShows(shows){
  return (shows||[]).filter(s=>{
    const b = baseFromItem(s);
    if (b?.anime === true) return true;
    if (Array.isArray(b?.genres) && b.genres.some(g=>String(g).toLowerCase()==='anime')) return true;
    return false;
  });
}

// search helpers (AI + fallbacks)
export async function searchMovieByTitleYear(title, year){
  const r = await jget('/search/movies', { q: title, year }).catch(()=>[]);
  return Array.isArray(r) ? r : [];
}
export async function searchShowByTitleYear(title, year){
  const r = await jget('/search/shows', { q: title, year }).catch(()=>[]);
  return Array.isArray(r) ? r : [];
}
export async function searchShowsByKeyword(q, limit=25){
  if (!q) return [];
  const r = await jget('/search/shows', { q, limit }).catch(()=>[]);
  return Array.isArray(r) ? r : [];
}
EOF

# =========================
#  buildCatalog.js
# =========================
RUN cat > src/buildCatalog.js <<'EOF'
import { detailsMovie, detailsShow, baseFromItem, simklIdOf } from './simklClient.js';

function normalizeImdb(v){
  if (!v) return null;
  const s = String(v);
  return s.startsWith('tt') ? s : `tt${s}`;
}
// movies => tmdb: -> tt... -> tvdb:
// series/anime => tvdb: -> tmdb: -> tt...
function toMetaId(kind, idsRaw) {
  if (!idsRaw) return null;
  const ids = { ...idsRaw };
  const imdb = normalizeImdb(ids.imdb);

  if (kind === 'movie') {
    if (ids.tmdb != null) return `tmdb:${ids.tmdb}`;
    if (imdb)            return imdb;
    if (ids.tvdb != null) return `tvdb:${ids.tvdb}`;
    return null;
  } else { // series or anime
    if (ids.tvdb != null) return `tvdb:${ids.tvdb}`;
    if (ids.tmdb != null) return `tmdb:${ids.tmdb}`;
    if (imdb)            return imdb;
    return null;
  }
}
async function enrich(kind, item){
  const sid = simklIdOf(item);
  if (sid == null) return null;
  try {
    const full = (kind==='movie') ? await detailsMovie(sid) : await detailsShow(sid);
    const b = baseFromItem(full);
    return { title: b.title || b.name, year: b.year || b.first_aired, ids: b.ids || {} };
  } catch { return null; }
}
export async function buildMetas(items, kind, { limit=50, concurrency=6 } = {}){
  const metas = [];
  let i = 0;
  while (i < items.length && metas.length < limit){
    const chunk = items.slice(i, i+concurrency);
    const enriched = await Promise.all(chunk.map(x => enrich(kind, x)));
    for (const e of enriched){
      if (!e) continue;
      const id = toMetaId(kind, e.ids);
      if (!id) continue;
      metas.push({
        id,
        type: (kind==='anime') ? 'series' : kind,
        name: e.title || 'Untitled',
        year: e.year || undefined
      });
      if (metas.length >= limit) break;
    }
    i += concurrency;
  }
  return metas;
}
EOF

# =========================
#  aiSuggest.js (OpenRouter optional)
# =========================
RUN cat > src/aiSuggest.js <<'EOF'
import fetch from 'node-fetch';

// Returns array of {title,year} suggested by the model (no reranking).
export async function aiSuggestTitles(kind, profileSummary, limit=60) {
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) return [];
  const model = process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet';
  const sys = `Generate ${kind} recommendations based ONLY on the user's viewing profile.
Output a JSON array of {"title":string,"year":number|string}. No prose.`;

  const user = { kind, profile: profileSummary, max: limit };

  try {
    const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model, temperature: 0.3,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: JSON.stringify(user) }
        ]
      })
    });
    const j = await r.json().catch(()=>null);
    const content = j?.choices?.[0]?.message?.content || '[]';
    try {
      const parsed = JSON.parse(content);
      const arr = Array.isArray(parsed) ? parsed : (Array.isArray(parsed.items) ? parsed.items : []);
      return arr.map(x => ({
        title: String(x?.title || '').trim(),
        year:  Number(x?.year) || (typeof x?.year === 'string' ? x.year : undefined)
      })).filter(x => x.title);
    } catch { return []; }
  } catch { return []; }
}
EOF

# =========================
#  index.js
# =========================
RUN cat > src/index.js <<'EOF'
import http from 'http';
import {
  userMovies, userShows,
  candidatesMoviesPersonalized,
  candidatesShowsPersonalized, filterAnimeFromShows,
  searchMovieByTitleYear, searchShowByTitleYear,
  baseFromItem, simklIdOf,
  poolShowsWide, searchShowsByKeyword
} from './simklClient.js';
import { buildMetas } from './buildCatalog.js';
import { aiSuggestTitles } from './aiSuggest.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL_MIN = Number(process.env.CACHE_TTL_MINUTES || 360);
const EXCLUDE = new Set((process.env.EXCLUDE_SOURCES || 'history,ratings,watchlist')
  .split(',').map(s=>s.trim().toLowerCase()).filter(Boolean));

const cache = new Map();
const now = ()=>Date.now();
const expired = (t)=> Date.now()>t;

const manifest = {
  id: 'org.simkl.picks',
  version: '2.5.0',
  name: 'SimklPicks (AI Suggestions)',
  description: 'AI-suggested unseen picks from your Simkl profile; Movies emit TMDB ids, Series/Anime emit TVDB ids for aiometadata.',
  resources: ['catalog'],
  types: ['movie','series'],
  idPrefixes: ['tmdb','tvdb','tt'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Series (AI, unseen)' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Movies (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Anime (AI, unseen)' }
  ]
};

function send(res, obj, code=200){
  const s = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store'
  });
  res.end(s);
}
function norm(a){ if (Array.isArray(a)) return a; if (a?.movies) return a.movies; if (a?.shows) return a.shows; if (a?.items) return a.items; if (a?.data) return a.data; return []; }
function toSimklSet(arr){ const S=new Set(); for(const x of arr||[]){ const b = x?.movie || x?.show || x || {}; const id=b?.ids?.simkl ?? b?.simkl_id ?? b?.id; if(id!=null) S.add(String(id)); } return S; }

async function seenSet(kind){
  const buckets = (kind==='movie') ? await userMovies() : await userShows(); // anime shares shows buckets
  const S = new Set();
  if (EXCLUDE.has('history'))   for (const id of toSimklSet(norm(buckets.history)))   S.add(id);
  if (EXCLUDE.has('ratings'))   for (const id of toSimklSet(norm(buckets.ratings)))   S.add(id);
  if (EXCLUDE.has('watchlist')) for (const id of toSimklSet(norm(buckets.watchlist))) S.add(id);
  return S;
}

// ---- helpers for AI + fallbacks ----
function profileSummaryFrom(buckets){
  const bag = new Map();
  const add = (g,w)=> bag.set(g,(bag.get(g)||0)+w);
  const mix = [].concat(buckets.history||[]).concat(buckets.ratings||[]);
  for (const x of mix) {
    const b = x?.movie || x?.show || x || {};
    const gs = b.genres || b.genre || [];
    const w  = x?.rating ? (Number(x.rating)||1) : (x?.watched_at ? 1.0 : 0.5);
    for (const g of gs) if (g) add(String(g).toLowerCase(), w);
  }
  const genres = Array.from(bag.entries()).map(([name,weight])=>({name,weight}));
  const years = mix.map(x => Number((x?.movie||x?.show||x||{}).year||0)).filter(Boolean);
  const recencyBias = years.length ? Math.max(0, (years.reduce((a,b)=>a+b,0)/years.length) - 1990) : 0;
  return { genres, recencyBias };
}
function topGenres(summary, n=6){
  return (summary?.genres||[])
    .slice()
    .sort((a,b)=> (b.weight||0)-(a.weight||0))
    .map(g=>g.name)
    .filter(Boolean)
    .slice(0,n);
}
function dedupeBySimklId(items){
  const seen = new Set(); const out=[];
  for (const x of items||[]) {
    const id = simklIdOf(x);
    const k = id==null ? JSON.stringify(x) : String(id);
    if (!seen.has(k)) { seen.add(k); out.push(x); }
  }
  return out;
}

async function aiSuggestedPool(kind){
  if (!process.env.OPENROUTER_API_KEY) return [];
  const buckets = (kind==='movie') ? await userMovies() : await userShows();
  const summary = profileSummaryFrom(buckets);
  const titles = await aiSuggestTitles(kind, summary, 60); // [{title,year}]
  const results = [];
  for (const t of titles) {
    try {
      const arr = (kind==='movie')
        ? await searchMovieByTitleYear(t.title, t.year)
        : await searchShowByTitleYear(t.title, t.year);
      if (arr && arr.length) results.push(arr[0]); // best match
    } catch {}
  }
  return results;
}

async function showsFallbackFromGenres(){
  const buckets = await userShows();
  const summary = profileSummaryFrom(buckets);
  const seeds = topGenres(summary, 6);
  const pools = [];
  for (const g of seeds) {
    const hits = await searchShowsByKeyword(g, 25);
    pools.push(...hits);
  }
  // extra attempt for anime-specific
  const animeHits = await searchShowsByKeyword('anime', 50);
  pools.push(...animeHits);
  return pools;
}

async function candidatesShowsSafe() {
  const wide = await poolShowsWide();
  if (wide && wide.length) return wide;
  return await showsFallbackFromGenres();
}

async function makeCatalog(kind){
  // 1) AI suggestions (optional)
  const aiPool = await aiSuggestedPool(kind);

  // 2) Non-AI personalized
  let nonAi;
  if (kind==='movie')  nonAi = await candidatesMoviesPersonalized();
  if (kind==='series') nonAi = await candidatesShowsSafe();
  if (kind==='anime')  nonAi = filterAnimeFromShows(await candidatesShowsSafe());

  // 3) Merge + dedupe
  const merged = dedupeBySimklId([...(aiPool||[]), ...(nonAi||[])]);

  // 4) Strict unseen
  const seen = await seenSet(kind);
  const filtered = norm(merged).filter(x => {
    const id = simklIdOf(x);
    return id==null ? true : !seen.has(String(id));
  });

  // 5) Enrich → external IDs → metas (with prefixed IDs)
  return buildMetas(filtered, kind, { limit: 50, concurrency: 6 });
}

http.createServer(async (req,res)=>{
  try{
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname==='/' || url.pathname==='/health') { res.writeHead(200,{'Content-Type':'text/plain'}); return res.end('ok'); }
    if (url.pathname==='/manifest.json') return send(res, manifest);
    if (url.pathname==='/env-check') return send(res, {
      ok:true,
      hasApiKey: !!process.env.SIMKL_API_KEY,
      hasAccessToken: !!process.env.SIMKL_ACCESS_TOKEN,
      aiEnabled: !!process.env.OPENROUTER_API_KEY
    });
    if (url.pathname==='/refresh') { cache.clear(); return send(res, {ok:true,cleared:true}); }

    if (url.pathname==='/ids-preview'){
      const kind = (url.searchParams.get('type')||'movie').toLowerCase();
      const ai   = await aiSuggestedPool(kind);
      let nonAi;
      if (kind==='movie')  nonAi = await candidatesMoviesPersonalized();
      if (kind==='series') nonAi = await candidatesShowsSafe();
      if (kind==='anime')  nonAi = filterAnimeFromShows(await candidatesShowsSafe());
      const merged = dedupeBySimklId([...(ai||[]), ...(nonAi||[])]);
      const out = norm(merged).slice(0,25).map(x => {
        const b = baseFromItem(x);
        return { title: b.title||b.name, year: b.year||b.first_aired, ids: b.ids||{} };
      });
      return send(res, { type: kind, items: out });
    }

    const isNew = parts[0]==='stremio' && parts[1]==='v1' && parts[2]==='catalog';
    const isOld = parts[0]==='catalog';
    if (isNew || isOld){
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i,'');
      let kind = null;
      if (id==='simklpicks.recommended-movies'  && type==='movie')  kind='movie';
      if (id==='simklpicks.recommended-series'  && type==='series') kind='series';
      if (id==='simklpicks.recommended-anime'   && type==='series') kind='anime';
      if (!kind) return send(res, { metas: [] });

      const C = cache.get(kind);
      if (C && !expired(C.exp)) return send(res, { metas: C.data });

      const metas = await makeCatalog(kind);
      cache.set(kind, { data: metas, exp: Date.now() + TTL_MIN*60*1000 });
      return send(res, { metas });
    }

    res.writeHead(404,{'Content-Type':'text/plain'}); res.end('Not found');
  }catch(e){
    send(res,{ error:{message:String(e?.message||e)} });
  }
}).listen(PORT, ()=>{
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
