// Prisma 7 的配置入口(p0 §0 五件套④⑤)。两件事在这里、且只能在这里:
//
// ④ **`.env` 不再自动加载**。官方原文:"we're no longer automatically loading
//    environment variables when invoking the Prisma CLI"。所以首行 dotenv,
//    且必须排在读 env 的代码之前。
// ⑤ **`datasource.url` 已从 schema 搬到这里**(schema 里再写 `url` 会直接报错,
//    实测:"The datasource property `url` is no longer supported in schema files")。
//
// 身份绑定就此钉死,不靠部署手册:
//   · CLI / migrate / seed 的 schema engine  → MIGRATOR_DATABASE_URL(DDL 身份)
//   · 运行时                                  → new PrismaPg({ connectionString: DATABASE_URL })
//     共享的运行时 client 到 P1 第一个消费者落地时才建(YAGNI,T3 没有消费者);
//     在那之前**唯一**的实例在 apps/server/src/infra/seed/seed.ts。
//
// `env()` 是 @prisma/config 的读取器:变量缺失时**抛错**而不是给 undefined。
// 这正是我们要的——Railway 的 preDeploy 继承 app service 的环境变量、没有
// per-command override(P0-T5 坑③),漏配一个变量必须当场炸,不能悄悄回落到
// Railway 注入的那条**超级用户**串上。
import 'dotenv/config'
import { defineConfig, env } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: {
    path: 'prisma/migrations',
    // v7 起 seed 不再隐式跑、也不再从 package.json 的 `prisma.seed` 读(p0 §0 五件套③)。
    // 种子刻意跑在 **app_runtime** 身份下(见 seed.ts 顶部注释):它一跑通,就等于
    // 把 migration 里那二十来条 GRANT 全过了一遍电。
    seed: 'pnpm exec tsx apps/server/src/infra/seed/seed.ts',
  },
  datasource: {
    url: env('MIGRATOR_DATABASE_URL'),
    // 刻意**不配** `shadowDatabaseUrl`:配了它 `migrate dev` 就要求那个库预先存在
    // (实测 P1003 `Database ... does not exist`,Prisma 不会替你建),等于为一条守卫
    // 往开发/CI 环境里加一个必须自己维护的数据库。CI 的漂移守卫改走
    // `migrate diff --from-config-datasource --to-schema`(拿**已迁移的真库**比 datamodel),
    // 不需要 shadow。`migrate dev` 仍自建临时 shadow(migrator 有 CREATEDB)。
  },
})
