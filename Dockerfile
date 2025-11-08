# ---- Base image ----
FROM node:20-alpine

# ---- App directory ----
WORKDIR /app

# ---- Dependencies ----
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.3.0",
  "type": "module",
  "dependencies": {
    "axios": "^1.7.2",
    "stremio-addon-sdk": "^1.6.0"
  },
  "scripts": {
    "start": "node src/index.js"
  }
}
EOF

RUN npm install --omit=dev

# ---- Source ----
RUN mkdir -p src

# simklClient.js with Bearer fix
RUN cat > src/simklClient.js <<'EOF'
import axios from "axios";

export default class SimklClient {
  constructor(apiKey, accessToken) {
    this.apiKey = apiKey;
    this.accessToken = accessToken;
    this.base = "https://api.simkl.com";
  }

  headers() {
    return {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "simkl-api-key": this.apiKey,
      ...(this.accessToken ? { "Authorization": `Bearer ${this.accessToken}` } : {})
    };
  }

  async fetch(path) {
    try {
      const { data } = await axios.get(`${this.base}${path}`, { headers: this.headers() });
      return data;
    } catch (err) {
      if (err.response)
        return `ERR ${err.response.status} ${err.response.statusText}`;
      return `ERR ${err.message}`;
    }
  }

  async userSummary() {
    return {
      historyMovies: await this.fetch("/sync/history/movies"),
      watchlistMovies: await this.fetch("/sync/watched/movies"),
      ratingsMovies: await this.fetch("/sync/ratings/movies"),
      historyShows: await this.fetch("/sync/history/shows"),
      watchlistShows: await this.fetch("/sync/watched/shows"),
      ratingsShows: await this.fetch("/sync/ratings/shows"),
      historyAnime: await this.fetch("/sync/history/anime"),
      watchlistAnime: await this.fetch("/sync/watched/anime"),
      ratingsAnime: await this.fetch("/sync/ratings/anime")
    };
  }
}
EOF

# ---- index.js ----
RUN cat > src/index.js <<'EOF'
import { addonBuilder } from "stremio-addon-sdk";
import SimklClient from "./simklClient.js";
import http from "http";

const PORT = Number(process.env.PORT) || 7769;
const simkl = new SimklClient(
  process.env.SIMKL_API_KEY,
  process.env.SIMKL_ACCESS_TOKEN
);

const manifest = {
  id: "org.simkl.picks",
  version: "1.3.0",
  name: "SimklPicks",
  description: "AI-style personalized picks from your Simkl data",
  resources: ["catalog"],
  types: ["movie", "series"],
  catalogs: [
    { type: "movie", id: "simklpicks.recommended-movies", name: "Simkl Picks: Movies" },
    { type: "series", id: "simklpicks.recommended-series", name: "Simkl Picks: Series" },
    { type: "series", id: "simklpicks.recommended-anime", name: "Simkl Picks: Anime" }
  ]
};

const builder = new addonBuilder(manifest);

builder.defineCatalogHandler(async ({ id }) => {
  const data = await simkl.userSummary();
  const list = Object.values(data).flat();
  const metas = Array.isArray(list)
    ? list.slice(0, 50).map(item => ({
        id: item.ids?.simkl?.toString() || "unknown",
        type: "movie",
        name: item.title || "Untitled",
        poster: item.poster || "",
        description: item.overview || ""
      }))
    : [];
  return { metas };
});

http.createServer((req, res) => {
  if (req.url === "/manifest.json") {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(manifest));
  } else if (req.url.startsWith("/debug-auth")) {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({
      ok: !!simkl.apiKey,
      hasApiKey: !!simkl.apiKey,
      hasAccessToken: !!simkl.accessToken
    }));
  } else {
    res.statusCode = 404;
    res.end("Not Found");
  }
}).listen(PORT, () => {
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

EXPOSE 7769
CMD ["npm", "start"]
