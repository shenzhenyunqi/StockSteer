# P0-T5 · 同一镜像双进程(07 §1):server / worker 只差 start command。
# 构建上下文是**仓库根**(workspace 依赖要跨包解析),Railway 的 Root Directory 留空、
# Dockerfile Path 填 apps/server/Dockerfile。
#
# syntax=docker/dockerfile:1
FROM node:22-slim AS base
ENV PNPM_HOME=/pnpm PATH=$PNPM_HOME:$PATH
RUN corepack enable
WORKDIR /app

# ── 依赖层 ───────────────────────────────────────────────────────────────────
# 先只拷清单再 install:源码改动不会让依赖层失效(Railway 每次 push 都重建,
# 这一层的缓存命中直接决定部署时长)。
FROM base AS deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/core/package.json      packages/core/
COPY packages/contracts/package.json packages/contracts/
COPY apps/server/package.json        apps/server/
COPY apps/web/package.json           apps/web/
RUN pnpm install --frozen-lockfile

# ── 构建层 ───────────────────────────────────────────────────────────────────
FROM deps AS build
COPY . .
# Prisma 7 取消了隐式 generate(p0 §0 五件套③),且 @prisma/config 的 env() **缺变量即抛**
# —— generate 本身不连库,但配置求值会先炸,所以这里喂两条**占位**串。它们只在
# 构建期存在、绝不进运行时镜像;运行时的真串由 Railway 环境变量注入。
RUN DATABASE_URL=postgresql://build:build@127.0.0.1:5432/build \
    MIGRATOR_DATABASE_URL=postgresql://build:build@127.0.0.1:5432/build \
    pnpm exec prisma generate
RUN pnpm -r build
# 去掉 devDependencies(typescript / vitest / eslint / vite …),运行时是纯负重。
# **不能用 `pnpm prune --prod`**:在 workspace 根上它按根项目算依赖,而根只有
# devDependencies —— 结果是 node_modules 被剪成 0、workspace 包的符号链接一起没了,
# 镜像能构建成功但一启动就 ERR_MODULE_NOT_FOUND(实测)。`install --prod` 才会
# 重建符号链接树、只留生产依赖。
RUN CI=true pnpm install --frozen-lockfile --prod --ignore-scripts

# ── 运行层 ───────────────────────────────────────────────────────────────────
FROM base AS runtime
ENV NODE_ENV=production
# 生成的 client 走 @prisma/adapter-pg → node-postgres,**没有 rust engine 二进制**
# (provider = "prisma-client"),所以运行层不需要 openssl 之类的额外系统库。
COPY --from=build /app /app
USER node
EXPOSE 8080
# worker 服务把它覆盖成 `node apps/server/dist/main.js worker`
CMD ["node", "apps/server/dist/main.js", "server"]
