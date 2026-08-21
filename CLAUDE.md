# StockSteer

Shopify + Amazon 双端库存调拨建议。**只读平台数据,永不写入**;执行永远在商家原后台。

## 规格在哪

实现级规格在 `specs/`(00–09 十件套 + `plan/p0–p7` 阶段计划),**刻意 gitignore,只活本机**——仓库 public,算式实现公开是知情接受的代价,规格不公开。克隆下来看不到 `specs/` 是正常的,不要重建。

`specs/` 内部优先级:`plan/` 覆盖 01–09(实现级、生成更晚)。

## 命令

首次克隆:`cp .env.example .env` → `pnpm install` → **`pnpm db:generate`**。
少了最后一步,`pnpm typecheck` 会报"找不到模块"——Prisma 7 取消了 postinstall 隐式生成;
少了第一步,连 `prisma generate` 都跑不了(`prisma.config.ts` 的 `env()` 缺变量直接抛,
实测 exit 1——这个"抛"是故意的,见该文件注释)。

```bash
pnpm -r build        # core → contracts → server → web
pnpm -r typecheck
pnpm lint
pnpm test            # vitest,unit / integration 两 project
pnpm test:unit       # golden tests
pnpm test:integration

pnpm db:up            # compose 起 PG + Redis(--wait 到 healthy)
pnpm db:migrate       # prisma migrate deploy(生产同一条)
pnpm db:migrate:dev   # 改了 schema.prisma 后生成 + 应用新 migration
pnpm db:generate      # 显式生成 client(v7 不再隐式跑)
pnpm db:seed          # 06 fixture;**以 app_runtime 身份跑**,顺带把全部 GRANT 过一遍电
pnpm db:verify        # 权限矩阵 + schema 不变量(两份脚本);改了权限或 schema 务必重跑
pnpm db:roles         # 只重跑角色脚本 —— 任何 prisma reset 之后必须跑(它会 DROP SCHEMA,把默认权限一起带走)
pnpm db:reset         # down -v 重建卷 + migrate + seed —— 改了 db/roles.sql、口令或 fixture 才走这条
pnpm db:down

# 镜像(P0-T5,同一镜像双进程;构建上下文是仓库根)
docker build -f apps/server/Dockerfile -t stocksteer .
docker run --rm -e DATABASE_URL=... stocksteer                                   # server(默认 CMD)
docker run --rm -e DATABASE_URL=... stocksteer node apps/server/dist/main.js worker
```

> 改 Dockerfile 时五条别踩回去(全都「构建成功、一启动/一部署就炸」,而且 **CI 一条都拦不住**
> —— CI 跑 compose 与源码树,不跑镜像):
> ① **`pnpm prune --prod` 在 workspace 根会把符号链接树剪没**(根只有 devDeps)→
> 用 `CI=true pnpm install --frozen-lockfile --prod`;
> ② **构建期 `prisma generate` 要喂占位连接串**(`@prisma/config` 的 `env()` 缺变量即抛);
> ③ **`prisma` / `dotenv` 是生产依赖**(preDeploy 的 migrate 在这个镜像里跑,`--prod` 会剪掉 devDeps);
> ④ **preDeploy 用 `./node_modules/.bin/prisma`,别用 `pnpm exec`**(USER node 撞 corepack 下载权限,`spawn prisma EACCES`);
> ⑤ **openssl 装在 base 层**,让构建层与运行层探测一致 —— `migrate` 走 Rust schema engine,
> 引擎变体在**安装期**按 libssl 探测结果下载;只在运行层装会下错变体、运行时想现下、写不动。
> 连带:prod install **不能加 `--ignore-scripts`**(否则引擎压根不下载)。

> **改了种子 fixture 的内容必须 `pnpm db:reset`**:种子对事件表用
> `ON CONFLICT DO NOTHING`(它只有 INSERT 权限,删不掉旧行),重跑是 no-op,旧值会留着。

> `db/init/` 只在数据卷**首次初始化**时执行。改了角色脚本而没 `db:reset`,你的库不会变。

## 边界(0 由 DB 权限兜底,1–4 由 eslint 硬拦)

> CI 已搭(`.github/workflows/ci.yml`:lint → typecheck → build → unit → integration 五段,push master + PR 触发)。日常在 `dev` 上做,PR 回 `master`。
> **闸门已配**(2026-08-20,ruleset `master 稳定分支保护`):master 只能经 PR 进、`ci` 必须绿、禁 force-push、禁删分支。实测直推 master 被拒:`GH013 … Changes must be made through a pull request. / Required status check "ci" is expected.`——不是"文件里写了",是推过一次真被拦。要改动这道闸门去 GitHub 的 repo rules,别指望改仓库里的文件。
> 各段的成色也不一样:**lint / typecheck / build 三段是活的门**(树里代码还极少,所以此刻拦得住的东西不多,但压力随代码增长自动加上来);`db:verify` 是活的(T3 后拆成两份:`verify-roles.sh` 权限模型 + `verify-schema.sh` 真实表上的不变量;**条数由脚本自己数并打印**,别在这里手写一个会漂的数字);**unit / integration 两段是空转的绿**——`--passWithNoTests` 让它们收集到 0 个测试也不红(CI 里为此挂 warning),golden tests 到 P1 才补。
> integration 段现在的实质内容是 `db:up → db:migrate → db:seed → db:verify`:空卷冷跑,所以「migrate 干净重放」每次 CI 都在重新兑现,不是谁本地跑过一次。
>
> 欠账清单(别只活在 PR 描述里):
> ① T4 spec 的验收「故意改坏 G1 期望被拦」**现在无法验**——G1 golden test 到 P1 才存在。延至 P1 首条 golden 落地后补验。
> ② P1 第一条测试落地时,同步去掉 `package.json` 里两处 `--passWithNoTests`。否则测试文件从 30 个掉到 2 个是看不见的,CI 那条计数 warning 只在掉到 0 时才响。
> ③ T3 验收「seed 后重算投影与 fixture 期望一致」**只兑现了一半**。重算需要 `ledger/fold.ts`(P1-T2)与 sales fold(P1-T3),今天树里没有。期望值已落在 `apps/server/src/infra/seed/fixture.ts` 的 `EXPECTED`(L1–L4 的投影值、V7/V8 的日桶),**P1-T2 落地当天补一条「删投影 → 全量重放 → 逐值相等」的集成测试**(即 golden L5)。今天已验的那一半是 store 层幂等键(种子真投了两次重复,`db/verify-schema.sh` 断言库里只有一条)——不是空话,但也不是全部。
> ④ **`channel_listings.fulfillment_fee_per_unit` 在 P4-T3 之前必须加**(FBA 每单位费用,02 §4 毛利的第三项)。数据源 `GET_FBA_ESTIMATED_FBA_FEES_TXT_DATA` 要 P6 才通,但 P4-T4 的验收是「golden A 组 5 卡在 UI 逐项复现」,而 P4-T3 从**库里**装载引擎输入——库里没有这个数,margin 就走降级路径、G1 归因变成 `margin unavailable`,当天验收不过。可变表,一条 migration;P4 期间数据先由 CSV/手工填。
> ⑤ **`reconciliation_rows` 缺 channel/state**(P3-T6 前)。correction 事件必须带 `(channel, state, qty)`,而行里没有 channel,超带裁决时造不出来;更实的风险是一个双挂牌 Product 的 DTC +50 / FBA −50 会合并成 delta 0 判成 Match,两个渠道都错。**故意留到 P3-T6**:行的粒度取决于拍板 1(对账超带裁决形态,≈9/1 才定),现在猜一个粒度比缺一个更难改。可变表。
> ⑥ **remap 事件无落点**(P6-T5 前)。01 §2「合并 Product 时追加 remap 事件,禁止 UPDATE」,而 `InvKind` 只有 snapshot|delta|correction,也没有 catalog 事件表。T3 spec 的表清单同样漏了。补法是加枚举值或新建一张表,都不属于「事件表补列」那类不可逆操作。
> ⑦ **`sku_mappings` 要不要「一个 listing 至多一条 confirmed」**(P6-T5 定)。复核建议加部分唯一索引,**暂不加**:没有任何 spec 声明过这条不变量,而商家给同一个 Shopify variant 挂两个 ASIN 是真实存在的形态——加错了会挡住合法数据,比缺一条约束更糟。P6-T5 拿真数据定。
> ⑧ **`shopify.app.stocksteer.toml` 的 `automatically_update_urls_on_dev` 要在 P0-T5 改成 `false`**。联调期靠它把 tunnel URL 写回 Partner Dashboard;Railway 上线后不改,本地一跑 `shopify app dev` 就会把线上 `application_url` / `redirect_urls` 冲掉,线上安装当场断。文件里留了注释,但注释不会在 P0-T5 那天自己响。
> ⑨ **测试订单判定的两笔账(P3-T3 实现 ACL 时兑现)**:① `excluded_reason` 在 append-only 表上,写错改不回 —— ACL 判定必须**保守**:平台未明确标 test 的一律 NULL(计入),把错判方向压成看得见的「多计入」(速度略高有人看得见,静默少计没人看得见)。**不加** override 表——那是给还没发生过的错判预付架构费。② 「什么算测试订单」的判定来源:Shopify 取 `order.test`;Amazon 侧是否有等价字段**未核**,P6-T3 前核实并写进 p6。

0. **DB 三身份,权限 fail-closed**。`migrator`(DDL)/ `app_runtime`(运行时)/ `app_purger`(只为 30 天物理删除而生:三张事件表的 SELECT+DELETE,别的一律没有)。
   **fail-closed**:`ALTER DEFAULT PRIVILEGES` 只给 `SELECT, INSERT`,新表天然 append-only;**可变表**要在自己的 migration 里显式 `GRANT UPDATE, DELETE`。漏写的表当场写不动——这是设计,不是 bug。运行时身份 `app_runtime` 永不持有事件表的 UPDATE/DELETE。
   **新表加了却忘了写 GRANT 不必等 P1 撞墙**:`db/verify-schema.sh` 的 B 段反查「除三张事件表 + `recommendation_cards` + `_prisma_migrations` 外,每张表都必须有 UPDATE+DELETE」,漏的那张会被点名。
   `recommendation_cards` 是特例:只给**列级** `UPDATE (status)`,表级 UPDATE 一律没有——08 §4「卡行不可变,自带快照」就此下到 DB,改 qty/explain 当场 42501。连带纪律:该 model **不能有 `@updatedAt`**,否则 Prisma 每次 update 都会顺手写那一列,状态迁移会全部被拒。
1. **`packages/core` 依赖白名单 = `zod` / `ulid` / `decimal.js`**,零 IO、零框架、不含子路径。时区用 Node 内置 `Intl`(不引库);CSV 切分不进 core(只做逐行纯翻译)。
2. **Prisma 只许出现在 `apps/server/src/infra/`** —— 包名与路径两条都拦。Prisma 7 起生成的 client 在源码树(`infra/prisma/generated/`),import 是相对路径而非 `@prisma/*`。唯一另一个例外是仓库根的 `prisma.config.ts`(CLI 只在那儿找它),例外面收到**精确文件名**。
   附带一条规则 5:**禁用 `tenantId_productId_cardType[_destChannel]` 这两个复合键**。active-slot 是**部分**唯一索引,但 Prisma 照样把复合键塞进 `WhereUniqueInput`(prisma#29282,7.9.1 实测复现)——`findUnique` 会 typecheck 全绿、运行时**任取一行**。查 active 卡一律 `findFirst({ where: { …, status: 'active' } })`。
3. **`apps/web` 禁类型断言** —— 接口类型一律从 `packages/contracts` 推断。
4. **core 除 `acl/` 外禁平台词汇**(fulfillable / available / committed / AFN / MFN)——平台语言不越过反腐层。

**幂等键 = `(tenant, source_ref)`;`source` 是溯源元数据,不在键里**(2026-08-21 裁决)—— source 参与身份的话,同一平台事实经 webhook 与 bulk 两条通道到达就无法互相去重,回填期间双计。`source_ref` 一律**全局命名空间化**,且必须对每一条产出的事件唯一:幂等键的失败形态是**静默丢弃**(01 §1),一条平台记录翻译出 N 条事件时(三态归一 → 3 条;一单 N 个 line item → N 条),少带一个维度的后果是**无声少记**,而事件表 append-only、少记的行没有重放面。身份取法分两类:**sales 取平台记录身份**(`shopify:order:{orderId}:{lineItemId}`,取消加 `:cancelled` —— 平台身份下取消与原单同前缀,漏了后缀负事件会撞键被吞),**库存 snapshot 取投递身份**(set-point 跨通道双到达无害,聚合观测没有单条平台记录可指——这是有意的分裂,别「统一」它)。约定见 `specs/plan/p3` 的「source_ref 约定」;`db/verify-schema.sh` H 段是回归位(键形结构断言 + 种子 XS 跨通道样本)。append 之后**必须核对写入行数**;少写的行**先按 (tenant, source_ref) 读回比对荷载**——内容相同 = 跨通道良性重复(键形改后是常态,静默),**内容不同才进 dead_letters**(规则与 sales 侧修复路径见 p3 推论;「少写一律进 dead_letters」的旧写法会被回填与全量重跑灌满,别改回去)。Amazon 侧 `amz:{orderId}:{sku}` 的完整性由 ACL **按 (orderId, sku) 聚合**构造——同单同 SKU 多 order item 是官方仓实证的真实形态,而报告侧拿不到可靠的 order-item-id,键里加不了维度(见 p6)。

**外键一律 `Restrict`/`NoAction`,全域无例外** —— 外键级联以被引用表的权限执行,能绕过上面第 0 条把事件行抹掉或改写;权限挡不住,只能在 FK 上堵。写 Prisma model 时必须**每条 `@relation` 都显式写**:v7 对必填关系的默认是 `onUpdate: Cascade`、对可选关系是 `onDelete: SetNull`,不写就默认溜进来。`db/verify-schema.sh` 的 D 段全域反查(附非空转自证)。

**生产权限自检随镜像走,不靠人手工跑**(P0-T5 裁决)。`apps/server/src/infra/db/assert-runtime-identity.ts` 在 `main.ts` 分派 server/worker **之前**执行,查三条:运行时身份非超级用户(Railway 注入的 `DATABASE_URL` 就是超级用户串,用了它 append-only 兜底当场归零)、三张事件表无 UPDATE/DELETE/**TRUNCATE**、public 下表 owner 均为 migrator。不过则拒绝启动。别把它挪进 `/healthz`——健康检查只报进程活着,不做级联判定,否则一次库抖动会被放大成停服。

大文件一律流式,整文件读进内存 = review 打回。

## 钉版

PostgreSQL **16** · Redis **7**(PG 大版本本地与 Railway 必须一致,一期不设 staging)· Node 22.x · TypeScript **5.9**(不上 7.0:typescript-eslint 8 的 peer 是 `<6.1.0`,lint 是硬门)· pnpm 10 · Prisma **7.9.1**(`provider = "prisma-client"`、`output` 必填、须装 `@prisma/adapter-pg`、`generate`/`db seed` 不再隐式跑)。

T3 落地时实测到的 Prisma 7 事实(都影响写法,别凭印象改回去):

- `datasource.url` 写进 schema **直接报错**,连接串只能在 `prisma.config.ts`;`seed` 也搬进了该文件的 `migrations.seed`(不再读 package.json 的 `prisma.seed`)。
- `@prisma/config` 的 `env()` **缺变量就抛**,`prisma generate` 也不例外(exit 1)。所以任何 prisma 命令前都得先有 `.env`。
- **`@@unique(..., nullsNotDistinct: true)` 不支持**(报 `No such argument`)。可空列参与的部分唯一索引必须拆成「非空一条 + 为空一条」两条,否则 PG 里 NULL 彼此不相等,约束形同虚设。
- 部分唯一索引要开 `previewFeatures = ["partialIndexes"]`,写法 `@@unique([...], where: raw("..."), map: "...")`,`raw()` 里用**数据库列名**。
- 手写进 migration 的 GRANT / DO 块**不会造成 drift**(`migrate status` 仍报 up to date)——shadow database 会连它们一起重放。
- 生成的 client `import "@prisma/client/runtime/client"`,所以 `@prisma/client` 是运行时依赖,不能只装 `prisma`。

## 工作方式:写-审-改分 agent

写完 spec 或代码后,**审那一步交给独立 agent**——不参与写作、不继承写作时的推理,只拿产物 + 上游约束找矛盾。触发点:spec/plan 写完、每个 P 阶段收口前、commit 前。

审要跑两条轴:**对外事实**(平台文档、库的真实行为)与**对内闭包**(下游任务需要的依赖/字段/能力 → 加总 → 对上游声明的约束)。2026-08-20 的教训:自审只跑了对外那条,p0 §0 里"只准三个库"与"要用一个 tz 库"隔两行的矛盾一直没被发现,动工第一天才撞上。

## 不变量(一票否决)

商家手工输入永不被自动过程改写 · 只读不写平台 · 每个建议数字可展开算式 + 归因 · 宁可拒绝服务不输出垃圾建议。
