FROM node:20 AS builder
ARG APP_VERSION

WORKDIR /app
RUN apt-get update && apt-get install -y wget
RUN yarn global add turbo

RUN wget https://github.com/lukevella/rallly/archive/refs/tags/${APP_VERSION}.tar.gz \
  && tar xzf ${APP_VERSION}.tar.gz \
  && mv rallly-*/.* rallly-*/* . 2>/dev/null || true \
  && rm -rf rallly-* ${APP_VERSION}.tar.gz
RUN turbo prune --scope=@rallly/web --docker

FROM node:20 AS installer

WORKDIR /app
COPY --from=builder /app/.gitignore .gitignore
COPY --from=builder /app/out/json/ .
COPY --from=builder /app/out/yarn.lock ./yarn.lock
RUN yarn --network-timeout 1000000

# Build the project
COPY --from=builder /app/out/full/ .
COPY --from=builder /app/turbo.json turbo.json
RUN yarn db:generate

ARG APP_VERSION
ENV NEXT_PUBLIC_APP_VERSION=$APP_VERSION

ARG SELF_HOSTED
ENV NEXT_PUBLIC_SELF_HOSTED=$SELF_HOSTED

RUN SKIP_ENV_VALIDATION=1 yarn build

FROM node:20-slim AS runner

# prisma requirements
# (see https://www.prisma.io/docs/orm/reference/system-requirements)
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    openssl \
    zlib1g \
    libgcc-s1 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN yarn global add prisma
# Don't run production as root
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
USER nextjs

COPY --from=builder --chown=nextjs:nodejs /app/scripts/docker-start.sh ./
COPY --from=builder --chown=nextjs:nodejs /app/packages/database/prisma ./prisma

COPY --from=installer /app/apps/web/next.config.js .
COPY --from=installer /app/apps/web/package.json .

ENV PORT=3000
EXPOSE 3000

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=installer --chown=nextjs:nodejs /app/apps/web/.next/standalone ./
COPY --from=installer --chown=nextjs:nodejs /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=installer --chown=nextjs:nodejs /app/apps/web/public ./apps/web/public

ARG SELF_HOSTED
ENV NEXT_PUBLIC_SELF_HOSTED=$SELF_HOSTED
ENV HOSTNAME=0.0.0.0

CMD ["./docker-start.sh"]