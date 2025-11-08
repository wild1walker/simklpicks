# ========= SimklPicks (SDK + CommonJS) =========
FROM node:20-alpine
WORKDIR /app

# ---- Dependencies (CommonJS) ----
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.4.0",
  "description": "Stremio addon: recommendations from your Simkl data",
  "main": "src/index.js",
  "type": "commonjs",
  "scripts": {
    "start": "node src/index.js"
  },
  "dependencies": {
    "axios": "^1.7.2",
    "stremio-addon-sdk": "^1.6.0"
  }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# ---- Simkl client (Bearer auth) ----
RUN cat > src/simklClient.cjs <<'EOF'
const axios = require('axios');

class SimklClient {
  constructor({ apiKey, accessToken }) {
    this.apiKey = apiKey;
    this.accessToken = accessToken;
    this.base = 'https://api.simkl.com';
  }
  headers() {
    return {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'simkl-api-key': this.apiKey,
      ...(this.accessToken ? { Authorization: `Bearer ${this.accessToken}` } : {})
    };
  }
  async _get(path) {
    const url = `${this.base}${path}`;
    const res = await axios.get(url, { headers: this.headers() });
    return res.data;
  }

  // Movies
  historyMovies()   { return this._get('/sync/history/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }

  // Series
  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }

  // Anime (as series)
  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }
}

module.exports = SimklClient;
EOF

# ---- Index: SDK manifest + handlers + serveHTTP ----
RUN cat > src/index.js <<'EOF'
const { addonBuilder, serveHTTP } = require('stremio-addon-sdk');
const SimklClient = require('./simklClient.cjs');

const PORT = Number(process.env.PORT) || 7769;

const manifest = {
  id: 'org.simkl.picks',
  version: '1.4.0',
  name: 'SimklPicks',
  description: 'Recommendations based on your Simkl watchlists/history',
  resources: ['catalog'],
  types: ['movie', 'series'],         // anime served under series
  idPrefixes: ['tt', 'tmdb', 'tvdb'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Recommended Series' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Recommended Movies' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Recommended Anime' }
  ]
};

const client = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN
});

function pickIds(base = {}) {
  const ids = base.ids || {};
  if (ids.imdb) return ids.imdb.toString().startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb) return `tmdb:${ids.tmdb}`;
  if (ids.tvdb) return `tvdb:${ids.tvdb}`;
  if (base.slug) return base.slug;
  return String(Math.random()).slice(2);
}

function toMeta(simklItem) {
  // Simkl item may be under .movie / .show / .anime or the root
  const b = simklItem.movie || simklItem.show || simklItem.anime || simklItem || {};
  return {
    id: pickIds(b),
    type: (b.type === 'movie' ? 'movie' : 'series'),
    name: b.title || b.name || b.show_title || b.movie_title || 'Untitled',
    poster: b.poster || b.image || undefined,
    posterShape: 'poster',
    year: b.year
  };
}

// Simple pool: prefer watchlist; fallback to ratings; last resort history (unseen filter can be added later)
async function getPoolFor(id, type) {
  try {
    if (id === 'simklpicks.recommended-movies' && type === 'movie') {
      const wl = await client.watchlistMovies();
      if (Array.isArray(wl) && wl.length) return wl.map(toMeta);
      const rt = await client.ratingsMovies();
      if (Array.isArray(rt) && rt.length) return rt.map(toMeta);
      const hi = await client.historyMovies();
      return Array.isArray(hi) ? hi.map(toMeta) : [];
    }
    if (id === 'simklpicks.recommended-series' && type === 'series') {
      const wl = await client.watchlistShows();
      if (Array.isArray(wl) && wl.length) return wl.map(toMeta);
      const rt = await client.ratingsShows();
      if (Array.isArray(rt) && rt.length) return rt.map(toMeta);
      const hi = await client.historyShows();
      return Array.isArray(hi) ? hi.map(toMeta) : [];
    }
    if (id === 'simklpicks.recommended-anime' && type === 'series') {
      const wl = await client.watchlistAnime();
      if (Array.isArray(wl) && wl.length) return wl.map(toMeta);
      const rt = await client.ratingsAnime();
      if (Array.isArray(rt) && rt.length) return rt.map(toMeta);
      const hi = await client.historyAnime();
      return Array.isArray(hi) ? hi.map(toMeta) : [];
    }
  } catch (e) {
    console.error('Simkl fetch failed:', e.message || e);
  }
  return [];
}

const builder = new addonBuilder(manifest);

builder.defineCatalogHandler(async ({ id, type /*, extra */ }) => {
  const pool = await getPoolFor(id, type);
  const metas = (pool || []).filter(m => m && m.id && m.name).slice(0, 50);
  return { metas };
});

// Expose /manifest.json and /stremio/v1/* routes (catalogs)
serveHTTP(builder.getInterface(), { port: PORT });
console.log(`[SimklPicks] listening on :${PORT}`);
console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
EOF

# ---- Runtime ----
ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
