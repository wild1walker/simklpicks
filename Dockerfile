FROM node:20-alpine
WORKDIR /app

# --- Minimal package.json ---
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "2.2.0",
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
  // IMPORTANT: Simkl expects NO "Bearer " prefix
  if (process.env.SIMKL_ACCESS_TOKEN) h['Authorization'] = process.env.SIMKL_ACCESS_TOKEN;
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
export async function userAnime(){ // anime shares shows buckets
  const [history,ratings,watchlist] = await Promise.all([
    jget('/sync/history/shows', ext).catch(()=>[]),
    jget('/sync/ratings/shows', ext).catch(()=>[]),
    jget('/sync/watchlist/shows', ext).catch(()=>[])
  ]);
  return {history,ratings,watchlist};
}

export function baseFromItem(x){
  return x?.movie || x?.show || x || {};
}
export function simklIdOf(x){
  const b = baseFromItem(x);
  return b?.ids?.simkl ?? b?.simkl_id ?? b?.id ?? null;
}

// -------- details lookups (ensures external IDs are present) --------
export async function detailsMovie(simklId){ return jget(`/movies/${simklId}`, ext); }
export async function detailsShow(simklId){  return jget(`/shows/${simklId}`,  ext); }

// -------- pool helpers (fallback sources that exist for all keys) ---
async function poolMoviesWide() {
  const lists = await Promise.all([
    jget('/movies/top',      ext).catch(()=>[]),
    jget('/movies/popular',  ext).catch(()=>[]),
    jget('/movies/trending', ext).catch(()=>[])
  ]);
  return lists.flat().filter(Boolean);
}
async function poolShowsWide() {
  const lists = await Promise.all([
    jget('/shows/top',      ext).catch(()=>[]),
    jget('/shows/popular',  ext).catch(()=>[]),
    jget('/shows/trending', ext).catch(()=>[])
  ]);
  return lists.flat().filter(Boolean);
}

// -------- profile from your history + ratings (not watchlist) -------
function genreBagFrom(items) {
  const bag = new Map();
  const add = (g, w=1)=> bag.set(g, (bag.get(g)||0)+w);
  for (const x of items || []) {
    const b = baseFromItem(x);
    const gs = b.genres || b.genre || [];
    const weight =
      x?.rating ? (Number(x.rating)||1) :
      (x?.watched_at ? 1.0 : 0.5);
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
  if (yr) s += Math.max(0, (yr - 1990)) * 0.01; // tiny recency nudge
  return s;
}
export async function buildProfile(kind) {
  const buckets = (kind === 'movie') ? await userMovies() : await userShows();
  const base = []
    .concat(buckets.history || [])
    .concat(buckets.ratings || []); // OMIT watchlist to avoid echo
  return genreBagFrom(base);
}

// -------- personalized candidates (movies, shows, anime) -----------
export async function candidatesMoviesPersonalized() {
  const pool = await poolMoviesWide();
  const bag  = await buildProfile('movie');
  return pool
    .map(it => ({ it, s: scoreByGenres(it, bag) }))
    .sort((a,b) => b.s - a.s)
    .map(x => x.it);
}
export async function candidatesShowsPersonalized() {
  const pool = await poolShowsWide();
  const bag  = await buildProfile('series');
  return pool
    .map(it => ({ it, s: scoreByGenres(it, bag) }))
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
export async function candidatesAnimePersonalized() {
  const rankedShows = await candidatesShowsPersonalized();
  return filterAnimeFromShows(rankedShows);
}
EOF

# =========================
#  buildCatalog.js
# =========================
RUN cat > src/buildCatalog.js <<'EOF'
import { detailsMovie, detailsShow, baseFromItem, simklIdOf } from './simklClient.js';

// aiometadata id format:
//   movie  -> TMDB number
//   series -> TVDB number
//   anime  -> TVDB number (Stremio "type" is still "series")
function aioId(ids, kind){
  if (!ids) return null;
  if (kind==='movie'){
    return (ids.tmdb!=null) ? String(ids.tmdb)
         : (ids.imdb!=null) ? (String(ids.imdb).startsWith('tt') ? String(ids.imdb) : `tt${ids.imdb}`)
         : (ids.tvdb!=null) ? String(ids.tvdb)
         : null;
  }
  // series / anime prefer tvdb
  return (ids.tvdb!=null) ? String(ids.tvdb)
       : (ids.tmdb!=null) ? String(ids.tmdb)
       : (ids.imdb!=null) ? (String(ids.imdb).startsWith('tt') ? String(ids.imdb) : `tt${ids.imdb}`)
       : null;
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
      const id = aioId(e.ids, kind);
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
#  index.js
# =========================
RUN cat > src/index.js <<'EOF'
import http from 'http';
import {
  userMovies, userShows,
  candidatesMoviesPersonalized,
  candidatesShowsPersonalized,
  candidatesAnimePersonalized,
  baseFromItem, simklIdOf
} from './simklClient.js';
import { buildMetas } from './buildCatalog.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL_MIN = Number(process.env.CACHE_TTL_MINUTES || 360);
const EXCLUDE = new Set((process.env.EXCLUDE_SOURCES || 'history,ratings,watchlist').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean));

const cache = new Map();
const now = ()=>Date.now();
const expired = (t)=> now()>t;

const manifest = {
  id: 'org.simkl.picks',
  version: '2.2.0',
  name: 'SimklPicks (AI)',
  description: 'Personalized unseen picks from your Simkl profile; Movies emit TMDB ids, Series/Anime emit TVDB ids for aiometadata.',
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

async function makeCatalog(kind){
  let cands;
  if (kind==='movie')  cands = await candidatesMoviesPersonalized();
  if (kind==='series') cands = await candidatesShowsPersonalized();
  if (kind==='anime')  cands = await candidatesAnimePersonalized();

  const seen = await seenSet(kind);
  const filtered = norm(cands).filter(x => {
    const id = simklIdOf(x);
    return id==null ? true : !seen.has(String(id));
  });

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
      exclude: Array.from(EXCLUDE)
    });
    if (url.pathname==='/refresh') { cache.clear(); return send(res, {ok:true,cleared:true}); }

    if (url.pathname==='/ids-preview'){
      const kind = (url.searchParams.get('type')||'movie').toLowerCase();
      // Show raw pool top slice (pre-unseen filtering) for debugging
      let cands;
      if (kind==='movie')  cands = await candidatesMoviesPersonalized();
      if (kind==='series') cands = await candidatesShowsPersonalized();
      if (kind==='anime')  cands = await candidatesAnimePersonalized();
      const out = norm(cands).slice(0,25).map(x => {
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
