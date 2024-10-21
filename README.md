# 部署 NextJS 与 App Router：不再只是 Vercel 的专属

存在一种误解，认为在 Vercel 基础设施之外部署使用新 App Router 的 NextJS 应用很困难。

事实并非如此。

本文将解释如何使用 Docker 和 Docker Compose 部署 NextJS 应用，其中 Nginx 负责提供静态资源并充当反向代理。

## 构建基石：涉及到的技术栈

该部署过程中使用的工具是：

1. NextJS：具有 App Router 的 React 框架。
2. Docker：容器化平台。
3. Docker Compose：管理多容器设置的工具。
4. Nginx：处理静态资源和反向代理请求的 Web 服务器。

### 第 1 步：准备您的 Next.js 应用

第一步是为 NextJS 应用准备部署。关键是在 `next.config.mjs` 文件中使用 `standalone` 输出选项。这会创建一个包含所有必要依赖项的独立构建。

以下是 `next.config.mjs` 的大致样子：

```react
/** @type {import('next').NextConfig} */
const nextConfig = {
    output: 'standalone',
};

export default nextConfig;
```

> 此配置更改告知 NextJS 将应用程序运行所需的所有内容打包在一起。

### 第二步：编写 Dockerfile

下一步是创建 Dockerfile。使用多阶段构建过程以保持最终镜像高效。

```dockerfile
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

```

该多阶段构建包含：

1. 依赖阶段：安装生产依赖项。
2. 构建阶段：构建 NextJS 应用，创建独立构建。
3. 运行阶段：设置运行 NextJS 应用的环境。
4. Nginx 阶段：准备 Nginx 服务器静态文件并提供反向代理功能。

### 步骤三：配置 Nginx

Nginx 已配置为适配当前应用的内容。以下是 `nginx.conf` 文件内容：

```nginx
user nginx;
worker_processes auto;

error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    upstream nextjs_upstream {
        server nextjs:3000;
        keepalive 64;
    }

    server {
        listen 80;
        server_name localhost;
        root /usr/share/nginx/html;

        location / {
            proxy_pass http://nextjs_upstream;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_cache_bypass $http_upgrade;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /_next/static {
            alias /usr/share/nginx/html/_next/static;
            expires 365d;
            access_log off;
            add_header Cache-Control "public, max-age=31536000, immutable";
        }

        location /static {
            expires 365d;
            access_log off;
            add_header Cache-Control "public, max-age=31536000, immutable";
        }

        location = /favicon.ico {
            log_not_found off;
            access_log off;
            expires 365d;
            add_header Cache-Control "public, max-age=31536000, immutable";
        }

        location = /robots.txt {
            log_not_found off;
            access_log off;
        }

        gzip_static on;
    }
}
```

此配置主要涉及以下内容：

1. 为 NextJS 应用设置上游服务器。
2. 配置处理不同类型请求的处理方式。
3. 设置缓存和性能优化。

### 第四步：用 Docker Compose 编排

Docker Compose 用于协调 NextJS 应用程序和 Nginx 镜像。以下是 `docker-compose.yml` 文件内容：

```docker-compose
services:
  nextjs:
    build:
      context: .
      target: runner
    container_name: nextjs-app
    restart: always

  nginx:
    build:
      context: .
      target: nginx
    container_name: nextjs-nginx
    restart: always
    ports:
      - "80:80"
    depends_on:
      - nextjs

networks:
  default:
    name: nextjs-network
```

此配置主要涉及以下内容：

1. 定义了两个服务：NextJS 应用和 Nginx。
2. 为它们建立一个通信网络。
3. 暴露端口 80 以供传入的 Web 流量使用。

### 部署流程

准备要部署应用程序：

1. 确保服务器上已安装 Docker 和 Docker Compose。
2. 上传 NextJS 项目文件、`Dockerfile`、`nginx.conf`和`docker-compose.yml`到服务器。
3. 切换到终端中的项目目录。
4. 运行命令：`docker-compose up -d --build` 。

此命令构建 Docker 镜像并以分离模式启动容器。

## 结论

使用 Docker 和 Nginx，在 Vercel 之外部署 NextJS 应用并使用 App Router 是可行的。这种设置创建了一个可以控制基础设施的部署环境。
