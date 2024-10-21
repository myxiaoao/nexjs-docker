# Stage 1: Dependencies
FROM node:22.6.0-alpine3.20 AS deps
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --only=production --no-audit --prefer-offline --silent

# Stage 2: Builder
FROM node:22.6.0-alpine3.20 AS builder
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED 1

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN npm run build

# Stage 3: Runner (Node.js app)
FROM node:22.6.0-alpine3.20 AS runner
WORKDIR /app

ENV NODE_ENV production
ENV NEXT_TELEMETRY_DISABLED 1

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/.next/standalone ./

EXPOSE 3000

CMD ["node", "server.js"]

# Stage 4: Nginx
FROM nginx:1.27.0-alpine3.19 AS nginx

# Copy the built Next.js static files
COPY --from=builder /app/public /usr/share/nginx/html
COPY --from=builder /app/.next/static /usr/share/nginx/html/_next/static

COPY --from=builder /app/app/favicon.ico /usr/share/nginx/html/favicon.ico

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
