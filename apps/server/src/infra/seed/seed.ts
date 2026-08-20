// P0-T3 · 种子脚本。`pnpm db:seed`(= `prisma db seed`,v7 起**不再隐式跑**)。
//
// ── 为什么跑在 app_runtime 身份下 ────────────────────────────────────────────
// 用 DATABASE_URL(运行时身份)而不是 MIGRATOR_DATABASE_URL:拿 migrator 跑种子
// 什么都证明不了(它是 owner,权限永远够),而以运行时身份跑,写路径上的权限
// 但凡少一条就当场炸。
//
// **但别把它当成 GRANT 完整性的守卫** —— 种子实际写到的是 7 张可变表
// (tenants / params / products / product_overrides / channel_listings /
// promo_events / promo_event_products)与 3 张事件表,migration 里放权的有 21 张。
// 「每张可变表的 GRANT 都写了」由 `db/verify-schema.sh` 的 B 段**反查**兜底
// (除例外名单外每张表都必须有 UPDATE+DELETE),不是靠这里。
// 之所以要写清楚:这个项目已经栽过四次「把守卫写成注释」,反过来写成
// 「注释宣告一个其实在别处的守卫」是同一个病。
//
// ── 幂等 ────────────────────────────────────────────────────────────────────
// 可变表走 upsert(id 是确定性的,见 fixture.ts),事件表走
// `createMany({ skipDuplicates: true })`(= ON CONFLICT DO NOTHING,只需 INSERT
// 权限)。所以重跑是 no-op。**改了 fixture 的内容则要 `pnpm db:reset`** ——
// 事件行删不掉(这是设计),旧值会留在库里。
//
// 环境变量由 prisma.config.ts 的 `import "dotenv/config"` 载入,经 `prisma db seed`
// 派生的子进程继承。直接 `tsx` 调用本文件时 .env 不会被读 —— 下面的守卫会说清楚。
import { PrismaPg } from '@prisma/adapter-pg'
import { Prisma, PrismaClient } from '../prisma/generated/client.js'
import {
  DEMO_ACCOUNT_HEALTH,
  DEMO_PRODUCTS,
  DEMO_PROMO,
  STOCKOUT_CASE,
  LEDGER_CASES,
  SALES_CASES,
  TENANT_DEMO,
  TENANT_LEDGER,
  dateOnly,
  fixtureId,
  spreadUnits,
  splitIntoOrders,
  storeTime,
  windowDay,
  WINDOW_DAYS,
  FROZEN_CLOCK,
} from './fixture.js'

const connectionString = process.env.DATABASE_URL
if (!connectionString) {
  throw new Error(
    'DATABASE_URL 未设置。种子要以 app_runtime 身份跑 —— 用 `pnpm db:seed`(经 prisma.config.ts 载入 .env),' +
      '别直接 tsx 调本文件。',
  )
}

const prisma = new PrismaClient({ adapter: new PrismaPg({ connectionString }) })

/** 渠道 → 事件来源(03 §4:报告快照 = snapshot 事件,webhook = delta 事件) */
const SOURCE_BY_CHANNEL = { DTC: 'shopify_bulk', FBA: 'amazon_report', FBM: 'amazon_report' } as const

type InventoryRow = Prisma.InventoryEventCreateManyInput
type SalesRow = Prisma.SalesEventCreateManyInput

async function seedTenants() {
  for (const t of [TENANT_DEMO, TENANT_LEDGER]) {
    await prisma.tenant.upsert({
      where: { id: t.id },
      create: { id: t.id, shopifyDomain: t.shopifyDomain, timezone: t.timezone, createdAt: t.createdAt },
      update: { shopifyDomain: t.shopifyDomain, timezone: t.timezone },
    })
    // params 刻意**一个值都不传** —— 全部走 DB 默认(= v7.4 默认)。
    // db/verify-schema.sh 拿 **ledger 租户**那一行逐字比 06 冻结的那套参数:
    // 默认值哪天被人改了,golden 看不见(它用的是 in-code 常量),但那条断言会响。
    await prisma.params.upsert({ where: { tenantId: t.id }, create: { tenantId: t.id }, update: {} })
  }
  // demo 租户额外播账号健康:02 §8「IPI 无默认(空值归因;**demo 用 512**)」,
  // G1 的归因行要 "IPI 512, entered Aug 12"。它**不能**播在 ledger 租户上,
  // 否则上面那条「DB 无默认」的断言就没有干净的样本可比了。
  await prisma.params.update({
    where: { tenantId: TENANT_DEMO.id },
    data: {
      ipiScore: DEMO_ACCOUNT_HEALTH.ipiScore,
      ipiEnteredAt: storeTime(DEMO_ACCOUNT_HEALTH.ipiEnteredOn, '00:00'),
    },
  })
}

async function seedDemoCatalog() {
  let listingN = 0
  let overrideN = 0
  for (const p of DEMO_PRODUCTS) {
    await prisma.product.upsert({
      where: { id: p.id },
      create: {
        id: p.id,
        tenantId: TENANT_DEMO.id,
        displaySku: p.sku,
        title: p.title,
        cogsSynced: p.cogs,
      },
      update: { displaySku: p.sku, title: p.title, cogsSynced: p.cogs },
    })
    for (const leg of p.legs) {
      const id = fixtureId('CHNSTG', ++listingN)
      await prisma.channelListing.upsert({
        where: { id },
        create: {
          id,
          tenantId: TENANT_DEMO.id,
          productId: p.id,
          channel: leg.channel,
          externalId: leg.externalId,
          price: leg.price,
        },
        update: { price: leg.price, listed: true },
      })
    }
    if (p.casePack !== undefined) {
      const id = fixtureId('PRDVRD', ++overrideN)
      await prisma.productOverride.upsert({
        where: { productId: p.id },
        create: { id, tenantId: TENANT_DEMO.id, productId: p.id, casePack: p.casePack },
        update: { casePack: p.casePack },
      })
    }
  }

  await prisma.promoEvent.upsert({
    where: { id: DEMO_PROMO.id },
    create: {
      id: DEMO_PROMO.id,
      tenantId: TENANT_DEMO.id,
      name: DEMO_PROMO.name,
      channel: DEMO_PROMO.channel,
      startsOn: dateOnly(DEMO_PROMO.startsOn),
      endsOn: dateOnly(DEMO_PROMO.endsOn),
      multiplier: DEMO_PROMO.multiplier,
      scope: DEMO_PROMO.scope,
    },
    update: { multiplier: DEMO_PROMO.multiplier, scope: DEMO_PROMO.scope },
  })
  let promoProductN = 0
  for (const productId of DEMO_PROMO.productIds) {
    const id = fixtureId('PRMPRD', ++promoProductN)
    await prisma.promoEventProduct.upsert({
      where: { promoEventId_productId: { promoEventId: DEMO_PROMO.id, productId } },
      create: { id, tenantId: TENANT_DEMO.id, promoEventId: DEMO_PROMO.id, productId },
      update: {},
    })
  }
}

async function seedLedgerCatalog() {
  for (const c of [...LEDGER_CASES, ...SALES_CASES, STOCKOUT_CASE]) {
    await prisma.product.upsert({
      where: { id: c.productId },
      create: { id: c.productId, tenantId: TENANT_LEDGER.id, displaySku: c.sku, title: c.title },
      update: { displaySku: c.sku, title: c.title },
    })
  }
}

/** 冻结时钟当日的库存快照(06 A 组给的 sellable / inbound) */
function demoInventoryRows(): InventoryRow[] {
  const rows: InventoryRow[] = []
  let n = 0
  const occurredAt = new Date(FROZEN_CLOCK)
  for (const p of DEMO_PRODUCTS) {
    for (const leg of p.legs) {
      const states: [('sellable' | 'reserved' | 'inbound'), number][] = [['sellable', leg.sellable]]
      if (leg.reserved !== undefined) states.push(['reserved', leg.reserved])
      if (leg.inbound !== undefined) states.push(['inbound', leg.inbound])
      for (const [state, qty] of states) {
        rows.push({
          id: fixtureId('NVEVNT', ++n),
          tenantId: TENANT_DEMO.id,
          productId: p.id,
          channel: leg.channel,
          kind: 'snapshot',
          state,
          qty,
          source: SOURCE_BY_CHANNEL[leg.channel],
          sourceRef: `seed:snapshot:${p.sku}:${leg.channel}:${state}`,
          occurredAt,
          recordedAt: occurredAt,
        })
      }
    }
  }
  return rows
}

/** L1–L4 的事件序列。recordedAt 按 deliveredNth 排,「后到」是真的后到。 */
function ledgerRows(): { real: InventoryRow[]; duplicates: InventoryRow[] } {
  const real: InventoryRow[] = []
  const duplicates: InventoryRow[] = []
  const deliveryBase = new Date('2026-08-16T21:00:00.000Z').getTime()
  let n = 1000
  for (const c of LEDGER_CASES) {
    for (const e of c.events) {
      const row: InventoryRow = {
        id: fixtureId('NVEVNT', ++n),
        tenantId: TENANT_LEDGER.id,
        productId: c.productId,
        channel: 'DTC',
        kind: e.kind,
        state: 'sellable',
        qty: e.qty,
        source: e.kind === 'correction' ? 'reconciliation' : 'shopify_webhook',
        // 重复投递用的是**同一个** source_ref —— 幂等键就是靠它命中
        sourceRef: `seed:${c.sku}:${e.duplicateOf ?? e.deliveredNth}`,
        occurredAt: storeTime(e.at.date, e.at.time),
        recordedAt: new Date(deliveryBase + e.deliveredNth * 60_000),
      }
      ;(e.duplicateOf === undefined ? real : duplicates).push(row)
    }
  }
  return { real, duplicates }
}

/** demo 租户 90 天销售流:v = units / 90(even 加权),每单 2 件、余数单 1 件 */
function demoSalesRows(): SalesRow[] {
  const rows: SalesRow[] = []
  let n = 0
  for (const p of DEMO_PRODUCTS) {
    for (const leg of p.legs) {
      const daily = spreadUnits(leg.units)
      for (let i = 0; i < WINDOW_DAYS; i++) {
        const date = windowDay(i)
        // 店铺当地 12:00 —— 离日界足够远,归日不受任何取整/偏移影响
        const occurredAt = storeTime(date, '12:00')
        const orders = splitIntoOrders(daily[i])
        for (let o = 0; o < orders.length; o++) {
          const orderRef = `seed-${p.sku}-${leg.channel}-${date}-${o + 1}`
          rows.push({
            id: fixtureId('SAEVNT', ++n),
            tenantId: TENANT_DEMO.id,
            productId: p.id,
            channel: leg.channel,
            kind: 'sale',
            qty: orders[o],
            orderRef,
            source: SOURCE_BY_CHANNEL[leg.channel],
            sourceRef: `seed:${orderRef}`,
            occurredAt,
            recordedAt: occurredAt,
          })
        }
      }
    }
  }
  return rows
}

/** V7 / V8 */
function salesCaseRows(): { real: SalesRow[]; duplicates: SalesRow[] } {
  const real: SalesRow[] = []
  const duplicates: SalesRow[] = []
  let n = 900_000
  for (const c of SALES_CASES) {
    for (const o of c.orders) {
      const row: SalesRow = {
        id: fixtureId('SAEVNT', ++n),
        tenantId: TENANT_LEDGER.id,
        productId: c.productId,
        channel: 'DTC',
        kind: o.kind,
        qty: o.qty,
        orderRef: o.orderRef,
        excludedReason: o.excludedReason ?? null,
        source: 'shopify_webhook',
        sourceRef: o.sourceRef,
        occurredAt: new Date(o.occurredAtUtc),
        recordedAt: new Date(o.occurredAtUtc),
      }
      ;(o.duplicate ? duplicates : real).push(row)
    }
  }
  return { real, duplicates }
}

/** V6:断货日自观测。第三张 append-only 表在种子里的唯一写路径。 */
function stockoutRows(): { real: Prisma.StockoutObservationCreateManyInput[]; duplicates: Prisma.StockoutObservationCreateManyInput[] } {
  const mk = (date: string, n: number) => ({
    id: fixtureId('STKZER', n),
    tenantId: TENANT_LEDGER.id,
    productId: STOCKOUT_CASE.productId,
    channel: STOCKOUT_CASE.channel,
    date: dateOnly(date),
    // 07:00 店铺时区那一次采样
    recordedAt: storeTime(date, '07:00'),
  })
  return {
    real: STOCKOUT_CASE.observedDates.map((d, i) => mk(d, i + 1)),
    duplicates: STOCKOUT_CASE.duplicateDates.map((d, i) => mk(d, 100 + i)),
  }
}

async function main() {
  await seedTenants()
  await seedDemoCatalog()
  await seedLedgerCatalog()

  const ledger = ledgerRows()
  const sales = salesCaseRows()
  const stockout = stockoutRows()

  const inv = await prisma.inventoryEvent.createMany({
    data: [...demoInventoryRows(), ...ledger.real],
    skipDuplicates: true,
  })
  const sal = await prisma.salesEvent.createMany({
    data: [...demoSalesRows(), ...sales.real],
    skipDuplicates: true,
  })
  const stk = await prisma.stockoutObservation.createMany({ data: stockout.real, skipDuplicates: true })

  // 重复投递单独发一批,断言 DB 一条都没收 —— 这是 L1 / V8 下半句「第二次静默丢弃」
  // **今天就能验**的那一半(store 层 UNIQUE 是第一道;fold 那道等 P1-T2)。
  const dupInv = await prisma.inventoryEvent.createMany({ data: ledger.duplicates, skipDuplicates: true })
  const dupSal = await prisma.salesEvent.createMany({ data: sales.duplicates, skipDuplicates: true })
  const dupStk = await prisma.stockoutObservation.createMany({ data: stockout.duplicates, skipDuplicates: true })
  if (dupInv.count !== 0 || dupSal.count !== 0 || dupStk.count !== 0) {
    throw new Error(
      `幂等键失守:重复投递本应被唯一键全部丢弃,` +
        `实际收下 inventory=${dupInv.count} sales=${dupSal.count} stockout=${dupStk.count}`,
    )
  }

  console.log(
    [
      `种子完成(身份 app_runtime;写路径覆盖 7 张可变表 + 3 张事件表 —— GRANT 完整性由 db/verify-schema.sh B 段反查)`,
      `  租户 2 · demo Product ${DEMO_PRODUCTS.length} · ledger 用例 ${LEDGER_CASES.length + SALES_CASES.length}`,
      `  本次新增 inventory_events ${inv.count} · sales_events ${sal.count} · stockout_observations ${stk.count}(重跑为 0 = 幂等)`,
      `  重复投递 ${ledger.duplicates.length + sales.duplicates.length + stockout.duplicates.length} 条,全部被唯一键丢弃 ✓`,
    ].join('\n'),
  )
}

try {
  await main()
} finally {
  await prisma.$disconnect()
}
