// 生产环境的权限自检(P0-T5;p0 §0 与 T5 验收「production 上权限断言全绿」的可执行路径)。
//
// ── 为什么是 node 而不是那两个 shell 脚本 ──────────────────────────────────────
// db/verify-roles.sh 与 db/verify-schema.sh 跑在**开发/CI**:它们要建探针表、要
// migrator 与 app_purger 两条串、要 psql。生产上这三样都没有:运行镜像是 node
// (无 psql)、只该持有运行时那条串、更不该有 DDL 权。原本的候选是「railway connect
// 从本机手工跑」—— 那是把守卫降级成对人的嘱托,正是 07 §8 明令否定的「靠纪律」,
// 而这个项目已经栽过四次同样的病(p0 §0 复核总结论)。
//
// 所以生产这条改成**随镜像走、每次启动自动重新兑现**的自检,与 CI 空卷冷跑同构:
// 断言不过 => 进程拒绝启动 => healthcheck 失败 => 部署不 promote。fail-closed。
//
// ── 只查这三条,不多不少 ──────────────────────────────────────────────────────
// 判据是「运行时身份自己能观测到、且失守就意味着 append-only 已经没有兜底」:
//   ① 不是超级用户 —— Railway 的 PG 是 unmanaged 模板,注入的 DATABASE_URL 就是
//      **postgres 超级用户**串,而超级用户绕过一切权限检查。漏配一次环境变量、
//      或哪天有人图省事贴了平台给的那条串,07 §8 的兜底在唯一要紧的环境里当场归零,
//      且**没有任何其它信号会响**。这是本文件存在的首要理由。
//   ② 三张事件表上没有 UPDATE / DELETE / TRUNCATE —— append-only 的实质。
//      TRUNCATE 必须在列:它能一条语句抹平账本,却不被 UPDATE/DELETE 的断言覆盖,
//      而给可变表批量放权时写成 GRANT ALL 会把它一并带进来(P0-T4 同款注记)。
//   ③ public 下的表 owner 都是 migrator —— owner 走错的话默认权限不生效
//      (ALTER DEFAULT PRIVILEGES 只对 migrator 建的对象生效),app_runtime 会
//      对那批表全盘无权或全盘有权,两种都不是设计。Railway 无 init 钩子、
//      auto-deploy 可能抢在 roles.sql 之前建表,这条就是那个场景的探针(p0 T5 坑②)。
//
// 探针表、purger 授予面、外键 referential action 这些**不查**:它们要么需要 DDL 权、
// 要么需要别的身份,在生产由 migration 自身携带(FK)与 CI 的两份脚本保证。
import type { PrismaClient } from '../prisma/generated/client.js'

const EVENT_TABLES = ['inventory_events', 'sales_events', 'stockout_observations'] as const
const FORBIDDEN = 'UPDATE, DELETE, TRUNCATE'

export async function assertRuntimeIdentity(client: PrismaClient): Promise<void> {
  const violations: string[] = []

  const [{ is_super, who }] = await client.$queryRaw<{ is_super: boolean; who: string }[]>`
    select rolsuper as is_super, current_user::text as who from pg_roles where rolname = current_user
  `
  if (is_super) {
    violations.push(
      `运行时身份 ${who} 是超级用户 —— 它绕过一切权限检查,append-only 兜底等于不存在。` +
        `多半是 DATABASE_URL 用了平台注入的那条串,应换成 app_runtime。`,
    )
  }

  // 一次查完三张表:少一次往返,且缺表(migration 没跑)与没权限两种情况能分开报
  const perms = await client.$queryRaw<{ table_name: string; exists: boolean; writable: boolean }[]>`
    select t.name                                        as table_name,
           to_regclass('public.' || t.name) is not null  as exists,
           coalesce(has_table_privilege(current_user, 'public.' || t.name, ${FORBIDDEN}), false) as writable
      from unnest(${[...EVENT_TABLES]}::text[]) as t(name)
  `
  for (const p of perms) {
    if (!p.exists) violations.push(`事件表 ${p.table_name} 不存在 —— migration 没跑完就起了进程?`)
    else if (p.writable) violations.push(`运行时对 ${p.table_name} 持有 ${FORBIDDEN} 之一 —— 账本可被改写/抹平`)
  }

  const [{ strays }] = await client.$queryRaw<{ strays: string }[]>`
    select coalesce(string_agg(tablename || '(owner=' || tableowner || ')', ', ' order by tablename), '') as strays
      from pg_tables where schemaname = 'public' and tableowner <> 'migrator'
  `
  if (strays) {
    violations.push(
      `public 下有非 migrator 所有的表:${strays} —— 默认权限对它们不生效` +
        `(ALTER DEFAULT PRIVILEGES 不追溯、只认 migrator 建的对象)。` +
        `补救:REASSIGN OWNED BY <当前 owner> TO migrator 再补 GRANT。`,
    )
  }

  if (violations.length > 0) {
    throw new Error(
      ['生产权限自检未通过 —— 拒绝启动(fail-closed,07 §8):', ...violations.map((v) => `  · ${v}`)].join('\n'),
    )
  }
}
