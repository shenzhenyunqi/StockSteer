# P0-T5 · 同一镜像双进程(07 §1):server / worker 只差 start command。
# 构建上下文是**仓库根**(workspace 依赖要跨包解析),Railway 的 Root Directory 留空、
# Dockerfile Path 填 apps/server/Dockerfile。
#
# syntax=docker/dockerfile:1
FROM node:22-slim AS base
# 两条 ENV 而不是一条:同一条 ENV 内变量还没生效,`PATH=$PNPM_HOME:$PATH` 会拿到空值
# (BuildKit 会警告 UndefinedVar)。此刻无害——corepack 的 shim 在 /usr/local/bin——
# 但属于「看着对其实没生效」,不留。
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
# openssl 必须装在 **base**、让构建层与运行层探测一致(实测踩过):`prisma migrate`
# 走 Rust schema engine(运行时 client 才是 rust-free),而 @prisma/engines 在
# **安装期**按当时探测到的 libssl 下对应变体。只在运行层装 openssl 的话,构建期
# 探测不到会下 openssl-1.1.x,运行期却探测到 3.0.x → 想现下 → USER node 写不动
# root 的 node_modules → "Can't write to .../@prisma/engines"。
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl \
 && rm -rf /var/lib/apt/lists/*
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
# **不能加 `--ignore-scripts`**:它会跳过 `@prisma/engines` 的 postinstall(下载
# schema engine 二进制),于是 `migrate deploy` 在运行时才去下,而运行层是 USER node、
# 写不了 root 拥有的 node_modules —— 报 "Can't write to .../@prisma/engines"(实测)。
# 放行名单已在 pnpm-workspace.yaml 的 onlyBuiltDependencies 里。
RUN CI=true pnpm install --frozen-lockfile --prod

# ── 运行层 ───────────────────────────────────────────────────────────────────
FROM base AS runtime
ENV NODE_ENV=production
COPY --from=build /app /app
USER node
EXPOSE 8080
# worker 服务把它覆盖成 `node apps/server/dist/main.js worker`
CMD ["node", "apps/server/dist/main.js", "server"]
