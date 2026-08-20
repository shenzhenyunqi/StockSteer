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

pnpm db:up            # compose 起 PG + Redis(--wait 到 healthy)
pnpm db:verify        # 双角色权限矩阵;改了权限务必重跑
pnpm db:roles         # 只重跑角色脚本 —— 任何 prisma reset 之后必须跑(它会 DROP SCHEMA,把默认权限一起带走)
pnpm db:reset         # down -v 重建卷(连 redis 数据一起炸)—— 改了 db/roles.sql 或口令才走这条
pnpm db:down
```

> `db/init/` 只在数据卷**首次初始化**时执行。改了角色脚本而没 `db:reset`,你的库不会变。

## 边界(0 由 DB 权限兜底,1–4 由 eslint 硬拦)

> CI 已搭(`.github/workflows/ci.yml`:lint → typecheck → build → unit → integration 五段,push master + PR 触发)。日常在 `dev` 上做,PR 回 `master`。
> **闸门已配**(2026-08-20,ruleset `master 稳定分支保护`):master 只能经 PR 进、`ci` 必须绿、禁 force-push、禁删分支。实测直推 master 被拒:`GH013 … Changes must be made through a pull request. / Required status check "ci" is expected.`——不是"文件里写了",是推过一次真被拦。要改动这道闸门去 GitHub 的 repo rules,别指望改仓库里的文件。
> 各段的成色也不一样:**lint / typecheck / build 三段是活的门**(树里代码还极少,所以此刻拦得住的东西不多,但压力随代码增长自动加上来);`db:verify` 的 28 条权限断言是活的;**unit / integration 两段是空转的绿**——`--passWithNoTests` 让它们收集到 0 个测试也不红(CI 里为此挂 warning),golden tests 到 P1 才补。
>
> 两笔欠账(P0 的 DoD 缺口,别只活在 PR 描述里):
> ① T4 spec 的验收「故意改坏 G1 期望被拦」**现在无法验**——G1 golden test 到 P1 才存在。延至 P1 首条 golden 落地后补验。
> ② P1 第一条测试落地时,同步去掉 `package.json` 里两处 `--passWithNoTests`。否则测试文件从 30 个掉到 2 个是看不见的,CI 那条计数 warning 只在掉到 0 时才响。

0. **DB 三身份,权限 fail-closed**。`migrator`(DDL)/ `app_runtime`(运行时)/ `app_purger`(只为 30 天物理删除而生:三张事件表的 SELECT+DELETE,别的一律没有)。
   **fail-closed**:`ALTER DEFAULT PRIVILEGES` 只给 `SELECT, INSERT`,新表天然 append-only;**可变表**要在自己的 migration 里显式 `GRANT UPDATE, DELETE`。漏写的表当场写不动——这是设计,不是 bug。运行时身份 `app_runtime` 永不持有事件表的 UPDATE/DELETE。
1. **`packages/core` 依赖白名单 = `zod` / `ulid` / `decimal.js`**,零 IO、零框架、不含子路径。时区用 Node 内置 `Intl`(不引库);CSV 切分不进 core(只做逐行纯翻译)。
2. **Prisma 只许出现在 `apps/server/src/infra/`** —— 包名与路径两条都拦。Prisma 7 起生成的 client 在源码树(`infra/prisma/generated/`),import 是相对路径而非 `@prisma/*`。
3. **`apps/web` 禁类型断言** —— 接口类型一律从 `packages/contracts` 推断。
4. **core 除 `acl/` 外禁平台词汇**(fulfillable / available / committed / AFN / MFN)——平台语言不越过反腐层。

**指向事件表的外键一律 `Restrict`/`NoAction`** —— 外键级联以被引用表的权限执行,能绕过上面第 0 条把事件行抹掉或改写;权限挡不住,只能在 FK 上堵。

大文件一律流式,整文件读进内存 = review 打回。

## 钉版

PostgreSQL **16** · Redis **7**(PG 大版本本地与 Railway 必须一致,一期不设 staging)· Node 22.x · TypeScript **5.9**(不上 7.0:typescript-eslint 8 的 peer 是 `<6.1.0`,lint 是硬门)· pnpm 10 · Prisma 7(`provider = "prisma-client"`、`output` 必填、须装 `@prisma/adapter-pg`、`generate`/`db seed` 不再隐式跑)。

## 工作方式:写-审-改分 agent

写完 spec 或代码后,**审那一步交给独立 agent**——不参与写作、不继承写作时的推理,只拿产物 + 上游约束找矛盾。触发点:spec/plan 写完、每个 P 阶段收口前、commit 前。

审要跑两条轴:**对外事实**(平台文档、库的真实行为)与**对内闭包**(下游任务需要的依赖/字段/能力 → 加总 → 对上游声明的约束)。2026-08-20 的教训:自审只跑了对外那条,p0 §0 里"只准三个库"与"要用一个 tz 库"隔两行的矛盾一直没被发现,动工第一天才撞上。

## 不变量(一票否决)

商家手工输入永不被自动过程改写 · 只读不写平台 · 每个建议数字可展开算式 + 归因 · 宁可拒绝服务不输出垃圾建议。
