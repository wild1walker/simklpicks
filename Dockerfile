FROM node:20-alpine

WORKDIR /app

# Copy ANY zip that’s in the repo (don’t care about its exact name)
COPY *.zip /tmp/app.zip

# Unzip to /app and, if there's a top-level folder, move its contents up
RUN apk add --no-cache unzip \
  && mkdir -p /app/_unzip \
  && unzip -q /tmp/app.zip -d /app/_unzip \
  && set -eux; \
     # find the first package.json somewhere under the unzip dir
     PKG_DIR="$(find /app/_unzip -type f -name package.json -printf '%h\n' | head -n1)"; \
     if [ -z "$PKG_DIR" ]; then echo "package.json not found in zip" && exit 1; fi; \
     # move its parent folder contents to /app
     mv "$PKG_DIR"/* /app/; \
     # if moving a nested folder, also move hidden files (.env.example etc) when present
     shopt -s dotglob nullglob || true; \
     if [ -d "$PKG_DIR" ]; then mv "$PKG_DIR"/.* /app/ 2>/dev/null || true; fi; \
  && rm -rf /app/_unzip /tmp/app.zip

# Install deps (we pinned a working SDK in package.json inside the zip)
RUN npm install --omit=dev

EXPOSE 7769
CMD ["npm","start"]
