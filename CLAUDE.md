# StockSteer

Shopify + Amazon 双端库存调拨建议。**只读平台数据,永不写入**;执行永远在商家原后台。

## 规格在哪

实现级规格在 `specs/`(00–09 十件套 + `plan/p0–p7` 阶段计划),**刻意 gitignore,只活本机**——仓库 public,算式实现公开是知情接受的代价,规格不公开。克隆下来看不到 `specs/` 是正常的,不要重建。

`specs/` 内部优先级:`plan/` 覆盖 01–09(实现级、生成更晚)。

## 命令

```bash
pnpm -r build        # core → contracts → server → web
pnpm -r typecheck
pnpm lint
pnpm test            # vitest,unit / integration 两 project
pnpm test:unit       # golden tests
pnpm test:integration
```

## 四条边界(eslint 硬拦,CI merge 条件)

1. **`packages/core` 依赖白名单 = `zod` / `ulid` / `decimal.js`**,零 IO、零框架、不含子路径。时区用 Node 内置 `Intl`(不引库);CSV 切分不进 core(只做逐行纯翻译)。
2. **Prisma 只许出现在 `apps/server/src/infra/`** —— 包名与路径两条都拦。Prisma 7 起生成的 client 在源码树(`infra/prisma/generated/`),import 是相对路径而非 `@prisma/*`。
3. **`apps/web` 禁类型断言** —— 接口类型一律从 `packages/contracts` 推断。
4. **core 除 `acl/` 外禁平台词汇**(fulfillable / available / committed / AFN / MFN)——平台语言不越过反腐层。

另有两条纪律靠 review 兜底:事件表 append-only(DB 权限兜底,不靠自觉)· 大文件一律流式,整文件读进内存 = 打回。

## 钉版

Node 22.x · TypeScript **5.9**(不上 7.0:typescript-eslint 8 的 peer 是 `<6.1.0`,lint 是硬门)· pnpm 10 · Prisma 7(`provider = "prisma-client"`、`output` 必填、须装 `@prisma/adapter-pg`、`generate`/`db seed` 不再隐式跑)。

## 不变量(一票否决)

商家手工输入永不被自动过程改写 · 只读不写平台 · 每个建议数字可展开算式 + 归因 · 宁可拒绝服务不输出垃圾建议。
