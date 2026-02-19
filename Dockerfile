# ---------------------------------------------------------------------------------------------------------------------
FROM node:24-bookworm AS dep-builder
WORKDIR /app
ARG USE_CHINA_NPM_REGISTRY=0
RUN \
    set -ex && \
    corepack enable pnpm && \
    if [ "$USE_CHINA_NPM_REGISTRY" = 1 ]; then \
        pnpm config set registry https://registry.npmmirror.com ; \
    fi;

COPY ./tsconfig.json ./patches ./pnpm-lock.yaml ./package.json /app/
RUN \
    set -ex && \
    export PUPPETEER_SKIP_DOWNLOAD=true && \
    pnpm install --frozen-lockfile && \
    pnpm rb

# ---------------------------------------------------------------------------------------------------------------------
FROM debian:bookworm-slim AS dep-version-parser
WORKDIR /ver
COPY ./package.json /app/
RUN \
    set -ex && \
    grep -Po '(?<="rebrowser-puppeteer": ")[^\s"]*(?=")' /app/package.json | tee /ver/.puppeteer_version && \
    grep -Po '(?<="@vercel/nft": ")[^\s"]*(?=")' /app/package.json | tee /ver/.nft_version && \
    grep -Po '(?<="fs-extra": ")[^\s"]*(?=")' /app/package.json | tee /ver/.fs_extra_version

# ---------------------------------------------------------------------------------------------------------------------
FROM node:24-bookworm-slim AS docker-minifier
WORKDIR /minifier
COPY --from=dep-version-parser /ver/* /minifier/

ARG USE_CHINA_NPM_REGISTRY=0
RUN \
    set -ex && \
    if [ "$USE_CHINA_NPM_REGISTRY" = 1 ]; then \
        pnpm config set registry https://registry.npmmirror.com ; \
    fi; \
    npm install -g corepack@latest && \
    corepack enable pnpm && \
    pnpm add @vercel/nft@$(cat .nft_version) fs-extra@$(cat .fs_extra_version) --save-prod

COPY . /app
COPY --from=dep-builder /app /app
WORKDIR /app

# The Fix: We must move EVERYTHING from app-minimal (code + modules) back to /app
RUN \
    set -ex && \
    pnpm build && \
    cp /app/scripts/docker/minify-docker.js /minifier/ && \
    export PROJECT_ROOT=/app && \
    node /minifier/minify-docker.js && \
    # Remove original bulky folders
    rm -rf /app/node_modules /app/scripts /app/lib && \
    # Move the minified code AND node_modules back to root
    if [ -d "/app/app-minimal" ]; then \
        cp -r /app/app-minimal/* /app/ && \
        rm -rf /app/app-minimal ; \
    fi; \
    ls -la /app && \
    du -hd1 /app

# ---------------------------------------------------------------------------------------------------------------------
FROM node:24-bookworm-slim AS chromium-downloader
WORKDIR /app
COPY ./.puppeteerrc.cjs /app/
COPY --from=dep-version-parser /ver/.puppeteer_version /app/.puppeteer_version
ARG TARGETPLATFORM
ARG USE_CHINA_NPM_REGISTRY=0
ARG PUPPETEER_SKIP_DOWNLOAD=1
RUN \
    set -ex ; \
    if [ "$PUPPETEER_SKIP_DOWNLOAD" = 0 ] && [ "$TARGETPLATFORM" = 'linux/amd64' ]; then \
        corepack enable pnpm && \
        pnpm --allow-build=rebrowser-puppeteer add rebrowser-puppeteer@$(cat /app/.puppeteer_version) --save-prod && \
        pnpm rb && \
        pnpx rebrowser-puppeteer browsers install chrome ; \
    else \
        mkdir -p /app/node_modules/.cache/puppeteer ; \
    fi;

# ---------------------------------------------------------------------------------------------------------------------
FROM node:24-bookworm-slim AS app
LABEL org.opencontainers.image.authors="https://github.com/DIYgod/RSSHub"
ENV NODE_ENV=production
ENV TZ=Asia/Shanghai
# Ensure the app knows where it is
ENV PROJECT_ROOT=/app 

WORKDIR /app

ARG TARGETPLATFORM
ARG PUPPETEER_SKIP_DOWNLOAD=1
RUN \
    set -ex && \
    apt-get update && \
    apt-get install -yq --no-install-recommends dumb-init git curl ; \
    if [ "$PUPPETEER_SKIP_DOWNLOAD" = 0 ]; then \
        if [ "$TARGETPLATFORM" = 'linux/amd64' ]; then \
            apt-get install -yq --no-install-recommends \
                ca-certificates fonts-liberation wget xdg-utils \
                libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libdrm2 \
                libexpat1 libgbm1 libglib2.0-0 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
                libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 ; \
        else \
            apt-get install -yq --no-install-recommends chromium && \
            echo "CHROMIUM_EXECUTABLE_PATH=$(which chromium)" | tee /app/.env ; \
        fi; \
        apt-get install -yq --no-install-recommends xvfb procps ; \
    fi; \
    rm -rf /var/lib/apt/lists/*

COPY --from=chromium-downloader /app/node_modules/.cache/puppeteer /app/node_modules/.cache/puppeteer
COPY --from=docker-minifier /app /app

EXPOSE 1200
ENTRYPOINT ["dumb-init", "--"]
CMD ["npm", "run", "start"]
