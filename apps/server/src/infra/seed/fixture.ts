// P0-T3 · 种子 fixture 的**数据定义**(纯数据 + 纯生成器,零 IO)。
// 写库在 seed.ts;分开是为了 P1 之后的集成测试能 import 期望值而不触发写入。
//
// ── 冻结时钟 ────────────────────────────────────────────────────────────────
// 2026-08-17(周一)—— 06 的参考时钟。店铺时区 America/Los_Angeles,
// 全部 fixture 日期都在 PDT(UTC−7)区间内,故 07:00 店铺时间 = 14:00Z、
// 12:00 店铺时间 = 19:00Z,换算是常数,不需要引任何时区库。
//
// ── 这份 fixture 覆盖什么、不覆盖什么(scope 裁决,2026-08-20)────────────────
// T3 spec 写的是「06 输入造的 fixture(G/S/V/L 事件流)」。逐组核下来,**能落成
// 一份共享数据集的只有事件流形态的那些**,原因是硬的不是懒的:
//
//   · **G 组(G1–G5)** → 落。四个 Product 的库存快照 + 90 天销售流,
//     就是 UI 开发要看的那份 demo 数据。
//   · **L 组(L1–L4)** → 落。幂等 / 乱序 / 屏障 / correction 全是事件序列,
//     且 L5(重算等价)天然是「replay 事件 → 比投影」的集成测试,DB 里必须有料。
//   · **V7 / V8** → 落。归日时区、取消反向事件,同样是纯事件序列。
//   · **V6** → 落(见 STOCKOUT_CASE)。断货日自观测是 append 到第三张事件表的动作,
//     不落的话 stockout_observations 在种子里一行都没有、写路径无人走过。
//   · **S1–S7 与 V1–V5** → **不落**。理由是「**没有消费者**」,不是「放不下」:
//     06 D 写明 A/B 组走「纯函数 + 手造输入」、V 组的注记是「A/B 组把 v 当输入」——
//     这些用例的消费者是 packages/core 里的纯函数测试,本来就不读库,硬塞进种子
//     只会造出没人读的 fixture。
//     (顺带纠正一版早先写在这里的错理由:说它们「都是租户级 params、一个租户放不下」
//      是不对的 —— S1–S5 全是 Product 级场景,同一租户下各占一个 Product 完全共存;
//      真正租户级的只有 S6 的入库限额余量与 S7 的 IPI。结论不变,理由要写对。)
//
// ── 这份 fixture **不**声称能复现什么 ───────────────────────────────────────
//   ① **毛利**。06 G1 给的 margin(DTC $9.10 / FBA $8.40)需要 FBA 每单位费用
//      ($4.05),而库里还没有存它的列(T3 按 YAGNI 不预留可变表的列)。
//      listing 价格与 cogs 取的是自洽的示意值。
//      ⚠ **期限是 P4-T3,不是 P6**:数据源(`GET_FBA_ESTIMATED_FBA_FEES_TXT_DATA`,
//      FBA Fee Preview Report)确实 P6 才通,但 **P4-T4 的验收是「golden A 组 5 卡在 UI
//      逐项复现、数字与归因行与 06 一致」**,而 P4-T3 的生产管道是**从库里**装载引擎输入。
//      库里没有 $4.05 → margin 算不出 → 走 02 §4 的降级路径 → G1 归因变成
//      "margin unavailable",P4-T4 当场不过。channel_listings 是可变表,加一列
//      `fulfillment_fee_per_unit` 就是一条 migration;P4 期间数据先由 CSV/手工填。
//   ② **G1 的 8.7/d**。06 原文标注它是「事件加权后,含 Prime ×1.8」。本 fixture
//      把它当作**基速**播种(783 件 ÷ 90 天),于是 P2 算出的前瞻加权速度会**高于**
//      8.7。这不是 bug 是取舍:反推基速要先钉死 forwardVelocity 的窗口语义
//      (P1-T4)与 Promo 的结束日(06 只给了起始 8/25,没给结束)。A 组 golden
//      本来就把 v 当输入喂,不从库里取。
//   ③ **Promo 结束日**。06 只说「8/25 起」。这里取 8/25–8/26(两天,Prime 常见
//      形态)—— 是 fixture 层的选择,不是从 06 推出来的。

/** 参考时钟(06 冻结)。引擎测试注入 now 的那个值。 */
export const FROZEN_CLOCK = '2026-08-17T14:00:00.000Z' // = 07:00 America/Los_Angeles

export const STORE_TZ = 'America/Los_Angeles'

/** 速度窗口:90 天,含冻结时钟当天。2026-05-20 .. 2026-08-17。 */
export const WINDOW_DAYS = 90
export const WINDOW_END = '2026-08-17'

/**
 * 确定性 ID:26 字符 Crockford base32(ULID 的字符集,**不含 I L O U**)。
 * 刻意不用 ulid() —— 种子必须可重复:同一条 fixture 每次跑出同一个 id,
 * 重跑就是幂等 upsert,而不是每次多一批孤儿行。顺带,psql 里一眼能看出这行是谁。
 */
export function fixtureId(tag: string, n: number): string {
  if (!/^[0-9A-HJKMNP-TV-Z]{6}$/.test(tag)) throw new Error(`tag 不是 6 位 Crockford base32: ${tag}`)
  return `01K5SEED${tag}${String(n).padStart(12, '0')}`
}

// ============================================================================
// 日期工具(fixture 内部用;真正的时区换算在 P1-T1 shared/dates.ts)
// ============================================================================

const DAY_MS = 86_400_000

/** 'YYYY-MM-DD' → UTC 午夜的 Date(@db.Date 列取 UTC 日期部分) */
export function dateOnly(iso: string): Date {
  return new Date(`${iso}T00:00:00.000Z`)
}

/** 'YYYY-MM-DD' 加减天数 */
export function shiftDate(iso: string, days: number): string {
  return new Date(dateOnly(iso).getTime() + days * DAY_MS).toISOString().slice(0, 10)
}

/** 店铺当地时刻 → UTC。fixture 全程 PDT(UTC−7),故偏移是常数 7 小时。 */
export function storeTime(isoDate: string, hhmm: string): Date {
  const [h, m] = hhmm.split(':').map(Number)
  return new Date(dateOnly(isoDate).getTime() + (h + 7) * 3_600_000 + m * 60_000)
}

/** 窗口内第 i 天(0 = 最早的一天) */
export function windowDay(i: number): string {
  return shiftDate(WINDOW_END, i - (WINDOW_DAYS - 1))
}

/**
 * 把 total 件均匀铺到 90 天(Bresenham,和恒等于 total,分布确定)。
 * even 加权下 v = total / 90 —— 这就是各 Product 速度的来源。
 */
export function spreadUnits(total: number): number[] {
  const out: number[] = []
  for (let i = 0; i < WINDOW_DAYS; i++) {
    out.push(Math.floor(((i + 1) * total) / WINDOW_DAYS) - Math.floor((i * total) / WINDOW_DAYS))
  }
  return out
}

/**
 * 一天的件数拆成订单:每单 2 件,余数单 1 件。
 * 给 02 §4 的 `$/order ÷ 尾随单均件数` 折算用。**实测单均件数 1.60–1.95**(不是 2):
 * 日件数普遍偏小,奇数日必出一张 1 件单,把均值拉下来。低端偏差约 20%,
 * 不影响 A 组 golden(v 是喂进去的输入),但别照着"≈2"去核对 MCF 折算。
 */
export function splitIntoOrders(units: number): number[] {
  const orders: number[] = []
  for (let left = units; left > 0; left -= 2) orders.push(Math.min(2, left))
  return orders
}

// ============================================================================
// 租户
// ============================================================================

export const TENANT_DEMO = {
  id: fixtureId('TENANT', 1),
  shopifyDomain: 'stocksteer-fixture.myshopify.com',
  timezone: STORE_TZ,
  /// 一年前安装 —— 90 天窗口全程可观测,断货日口径不打折(02 §1)
  createdAt: new Date('2025-08-17T00:00:00.000Z'),
} as const

/**
 * demo 租户的账号健康。02 §8 原文「IPI 无默认(空值归因;**demo 用 512**)」,
 * 06 冻结参数表写「IPI 512, no limit」,G1 的归因行是「health 行(IPI 512, entered Aug 12)」。
 * 所以「DB 无默认」与「demo 有 512」两件事都要成立 —— 前者由 ledger 租户那一行证明
 * (它一个值都不传),后者由这里播下。两个断言因此互不打架。
 */
export const DEMO_ACCOUNT_HEALTH = {
  ipiScore: 512,
  /** 录入日期。02 §5:健康引用一律带录入日期(缺口 4) */
  ipiEnteredOn: '2026-08-12',
} as const

export const TENANT_LEDGER = {
  id: fixtureId('TENANT', 2),
  shopifyDomain: 'stocksteer-ledger-fixture.myshopify.com',
  timezone: STORE_TZ,
  createdAt: new Date('2025-08-17T00:00:00.000Z'),
} as const

// ============================================================================
// G 组:demo 租户的四个 Product(06 A 组的输入)
// ============================================================================

type Leg = {
  channel: 'DTC' | 'FBA' | 'FBM'
  /** 冻结时钟当日的 sellable 快照 */
  sellable: number
  /** FBA 侧的 inbound 快照;undefined = 该渠道不报这个态 */
  inbound?: number
  /**
   * Reserved 快照(01 §3:FBA reserved / Shopify committed / FBM 已售未发货)。
   * **06 没给这个数**——它是 fixture 层的示意值(约两天销量),因为 Reserved
   * 「只展示、不进任何算式」(01 §3),播它不影响 cover/触发/调拨量,却能让
   * 04 §4 的「On hand 三态 × 渠道」屏在 P4 开发时不是半空的。
   */
  reserved?: number
  /** 90 天窗口内的总件数;v = units / 90 */
  units: number
  /** 挂牌价(示意值,见文件头「不声称能复现毛利」) */
  price: string
  externalId: string
}

export type FixtureProduct = {
  id: string
  sku: string
  title: string
  /** Shopify unitCost(02 §4 成本链第一档),示意值 */
  cogs: string
  casePack?: number
  legs: Leg[]
}

export const DEMO_PRODUCTS: FixtureProduct[] = [
  {
    // G1(MOVE STOCK)+ G5(STOCKOUT ETA)
    id: fixtureId('PRDCT0', 1),
    sku: 'CNDL-AMB-8OZ',
    title: 'Amber Candle 8oz',
    cogs: '11.45',
    casePack: 24,
    legs: [
      { channel: 'FBA', sellable: 96, reserved: 17, inbound: 0, units: 783, price: '23.90', externalId: 'CNDL-AMB-8OZ' }, // 8.7/d
      { channel: 'DTC', sellable: 520, reserved: 14, units: 630, price: '24.00', externalId: 'gid-variant-1001' }, //         7.0/d
    ],
  },
  {
    // G2(MCF POOL)
    id: fixtureId('PRDCT0', 2),
    sku: 'CNDL-VNL-8OZ',
    title: 'Vanilla Candle 8oz',
    cogs: '11.45',
    legs: [
      { channel: 'FBA', sellable: 210, reserved: 10, inbound: 0, units: 459, price: '23.90', externalId: 'CNDL-VNL-8OZ' }, // 5.1/d
      { channel: 'DTC', sellable: 80, reserved: 6, units: 288, price: '24.00', externalId: 'gid-variant-1002' }, //            3.2/d
    ],
  },
  {
    // G3(MOVE STOCK,无 Promo)
    id: fixtureId('PRDCT0', 3),
    sku: 'DIFF-RD-100ML',
    title: 'Reed Diffuser 100ml',
    cogs: '9.20',
    casePack: 20,
    legs: [
      { channel: 'FBA', sellable: 78, reserved: 8, inbound: 0, units: 369, price: '19.50', externalId: 'DIFF-RD-100ML' }, // 4.1/d
      { channel: 'DTC', sellable: 310, reserved: 5, units: 216, price: '19.90', externalId: 'gid-variant-1003' }, //           2.4/d
    ],
  },
  {
    // G4(SHARED POOL:DTC + FBM 双挂牌 → 推定同池,01 §4)
    id: fixtureId('PRDCT0', 4),
    sku: 'SOAP-LAV-3PK',
    title: 'Lavender Soap 3-pack',
    cogs: '6.10',
    legs: [
      { channel: 'DTC', sellable: 140, reserved: 8, units: 351, price: '14.00', externalId: 'gid-variant-1004' }, //  3.9/d
      { channel: 'FBM', sellable: 140, reserved: 5, units: 225, price: '14.00', externalId: 'SOAP-LAV-3PK' }, //       2.5/d
    ],
  },
]

/**
 * G1 的 Promo Event(02 §1:全手工,不预置不自学;乘数只乘前瞻)。
 * 结束日 06 未给,取两天(见文件头 ③)。
 */
export const DEMO_PROMO = {
  id: fixtureId('PRMEVT', 1),
  name: 'Prime Day',
  channel: 'FBA' as const,
  startsOn: '2026-08-25',
  endsOn: '2026-08-26',
  multiplier: '1.800',
  scope: 'selected_products' as const,
  productIds: [DEMO_PRODUCTS[0].id],
}

// ============================================================================
// L 组 + V7/V8:ledger 租户,每个用例一个 Product(互不干扰)
// ============================================================================

export type LedgerEvent = {
  kind: 'snapshot' | 'delta' | 'correction'
  qty: number
  /** 店铺当地时刻 */
  at: { date: string; time: string }
  /** 投递(写入)顺序;06 的乱序用例靠它表达「后到」 */
  deliveredNth: number
  /** 同一 source_ref 重复投递 —— 期望被 UNIQUE(tenant, source, source_ref) 静默丢弃 */
  duplicateOf?: number
}

export type LedgerCase = {
  productId: string
  sku: string
  title: string
  /** 06 L 组给的期望投影值(sellable / DTC)。P1-T2 的 L5 重放测试拿它做断言。 */
  expectedSellable: number
  events: LedgerEvent[]
}

const L_DAY = '2026-08-16'

export const LEDGER_CASES: LedgerCase[] = [
  {
    // L1 幂等:同一 (source, source_ref) 投递两次 → 第二次静默丢弃,投影不变
    productId: fixtureId('PRDCT0', 11),
    sku: 'LEDGER-L1-IDEMPOTENT',
    title: 'L1 · 幂等',
    expectedSellable: 100,
    events: [
      { kind: 'snapshot', qty: 100, at: { date: L_DAY, time: '08:00' }, deliveredNth: 1 },
      // qty 故意写 999:若 UNIQUE 没拦住,投影会变成 999,断言立刻看得见
      { kind: 'snapshot', qty: 999, at: { date: L_DAY, time: '08:00' }, deliveredNth: 2, duplicateOf: 1 },
    ],
  },
  {
    // L2 乱序 delta:−3(10:00)先到、−2(09:00)后到 → 按 occurred_at 折叠 = 95
    productId: fixtureId('PRDCT0', 12),
    sku: 'LEDGER-L2-OUT-OF-ORDER',
    title: 'L2 · 乱序 delta',
    expectedSellable: 95,
    events: [
      { kind: 'snapshot', qty: 100, at: { date: L_DAY, time: '08:00' }, deliveredNth: 1 },
      { kind: 'delta', qty: -3, at: { date: L_DAY, time: '10:00' }, deliveredNth: 2 },
      { kind: 'delta', qty: -2, at: { date: L_DAY, time: '09:00' }, deliveredNth: 3 },
    ],
  },
  {
    // L3 snapshot 屏障:120@12:00 之后只剩 −4;再补到的旧 snapshot 90@07:00 不覆盖新 = 116
    productId: fixtureId('PRDCT0', 13),
    sku: 'LEDGER-L3-BARRIER',
    title: 'L3 · snapshot 屏障',
    expectedSellable: 116,
    events: [
      { kind: 'snapshot', qty: 100, at: { date: L_DAY, time: '08:00' }, deliveredNth: 1 },
      { kind: 'delta', qty: -5, at: { date: L_DAY, time: '09:00' }, deliveredNth: 2 },
      { kind: 'snapshot', qty: 120, at: { date: L_DAY, time: '12:00' }, deliveredNth: 3 },
      { kind: 'delta', qty: -4, at: { date: L_DAY, time: '13:00' }, deliveredNth: 4 },
      { kind: 'snapshot', qty: 90, at: { date: L_DAY, time: '07:00' }, deliveredNth: 5 },
    ],
  },
  {
    // L4 correction:超带裁决平台胜 → 追加 correction(绝对值 80),原事件不改不删
    productId: fixtureId('PRDCT0', 14),
    sku: 'LEDGER-L4-CORRECTION',
    title: 'L4 · correction',
    expectedSellable: 80,
    events: [
      { kind: 'snapshot', qty: 100, at: { date: L_DAY, time: '08:00' }, deliveredNth: 1 },
      { kind: 'correction', qty: 80, at: { date: L_DAY, time: '12:00' }, deliveredNth: 2 },
    ],
  },
]

export type SalesCase = {
  productId: string
  sku: string
  title: string
  /** 期望的 daily_units 桶(店铺时区日期 → 件数);P1-T3 的断言拿它比 */
  expectedBuckets: Record<string, number>
  orders: {
    kind: 'sale' | 'cancellation'
    qty: number
    /** UTC 时刻,**刻意写成 UTC** —— V7 要的就是跨时区那一下 */
    occurredAtUtc: string
    orderRef: string
    sourceRef: string
    /** 非空 = 不计入日桶(02 §1 测试订单;p0 §0 裁决入库 + 标记) */
    excludedReason?: string
    /** 重复投递(V8 下半句):期望被 UNIQUE 丢弃 */
    duplicate?: boolean
  }[]
}

export const SALES_CASES: SalesCase[] = [
  {
    // **多 line item 同键**(2026-08-20 复核发现的 BLOCKER 的活体样本)。
    // 一条 orders/create webhook 带 N 个 line item → N 行 sales_events。原 p3 约定
    // 把 source_ref 定成 `X-Shopify-Webhook-Id`(**每 webhook 一个值**),于是 N 行同键,
    // 而 01 §1 规定重复投递**静默丢弃** —— 第 2 行起无声消失,速度偏低、卡直接不出。
    // 这里播的是修正后的约定 `{webhookId}:{lineItemId}`,而且刻意用**同一个 SKU 的
    // 两个 line item**(最难的那种:给唯一键加 product_id 也救不了)。
    // db/verify-schema.sh 断言这两行都在。
    productId: fixtureId('PRDCT0', 17),
    sku: 'LEDGER-ML-MULTILINE',
    title: 'ML · 一单多 line item(同 SKU)',
    expectedBuckets: { '2026-08-12': 5 },
    orders: [
      {
        kind: 'sale',
        qty: 2,
        occurredAtUtc: '2026-08-12T19:00:00.000Z',
        orderRef: 'ml-order-1',
        sourceRef: 'seed:wh-ml-1:line-1',
      },
      {
        kind: 'sale',
        qty: 3,
        occurredAtUtc: '2026-08-12T19:00:00.000Z',
        orderRef: 'ml-order-1',
        sourceRef: 'seed:wh-ml-1:line-2',
      },
    ],
  },
  {
    // 测试订单(02 §1「计入 = 非取消、**非测试订单**件数」)。
    // p0 §0 裁决:**入库 + 标记**,不在 ACL 丢弃。日桶只算 excluded_reason 为空的那条。
    productId: fixtureId('PRDCT0', 18),
    sku: 'LEDGER-TEST-ORDER',
    title: '测试订单不计入',
    expectedBuckets: { '2026-08-13': 4 },
    orders: [
      {
        kind: 'sale',
        qty: 4,
        occurredAtUtc: '2026-08-13T19:00:00.000Z',
        orderRef: 'real-order-1',
        sourceRef: 'seed:wh-to-1:line-1',
      },
      {
        kind: 'sale',
        qty: 99,
        occurredAtUtc: '2026-08-13T19:00:00.000Z',
        orderRef: 'test-order-1',
        sourceRef: 'seed:wh-to-2:line-1',
        excludedReason: 'test_order',
      },
    ],
  },
  {
    // V7 归日时区:UTC 2026-08-15 03:00 = 店铺 8/14 20:00 → 计入 8/14 桶
    productId: fixtureId('PRDCT0', 15),
    sku: 'LEDGER-V7-STOREDAY',
    title: 'V7 · 归日时区',
    expectedBuckets: { '2026-08-14': 2 },
    orders: [
      { kind: 'sale', qty: 2, occurredAtUtc: '2026-08-15T03:00:00.000Z', orderRef: 'v7-1', sourceRef: 'seed:v7:1' },
    ],
  },
  {
    // V8 取消反向事件:8/10 下单 3 件,8/16 取消投递 → 追加 cancellation(qty −3,
    // occurred_at = 原下单时间)→ 8/10 桶净 0。重复投递第二次静默丢弃。
    productId: fixtureId('PRDCT0', 16),
    sku: 'LEDGER-V8-CANCELLATION',
    title: 'V8 · 取消反向事件',
    expectedBuckets: { '2026-08-10': 0 },
    orders: [
      { kind: 'sale', qty: 3, occurredAtUtc: '2026-08-10T19:00:00.000Z', orderRef: 'v8-1', sourceRef: 'seed:v8:sale' },
      {
        kind: 'cancellation',
        qty: -3,
        occurredAtUtc: '2026-08-10T19:00:00.000Z',
        orderRef: 'v8-1',
        sourceRef: 'seed:v8:cancel',
      },
      {
        kind: 'cancellation',
        qty: -3,
        occurredAtUtc: '2026-08-10T19:00:00.000Z',
        orderRef: 'v8-1',
        sourceRef: 'seed:v8:cancel',
        duplicate: true,
      },
    ],
  },
]

/**
 * V6 断货日自观测(02 §1 2026-08-20 裁决,06 V6)。
 * 每日 07:00 店铺时区单点采样,sellable=0 → 当天记一行。
 * 8/15 07:00 采样为 0 → 记;8/16 白天跌零但 8/16 与 8/17 的 07:00 采样都 >0 → **不记**。
 * 「不记」这一半没法用一行数据表达,所以它由「库里只有 8/15 一行」这个断言承担。
 * 另附一条同日重复采样,期望被 UNIQUE(tenant, product, channel, date) 丢弃。
 */
export const STOCKOUT_CASE = {
  productId: fixtureId('PRDCT0', 19),
  sku: 'LEDGER-V6-STOCKOUT',
  title: 'V6 · 断货日自观测',
  channel: 'DTC' as const,
  /** 记下的日子。8/16 刻意不在里面 —— 白天闪断不记 */
  observedDates: ['2026-08-15'],
  /** 同日重复采样,期望一条都进不去 */
  duplicateDates: ['2026-08-15'],
}

/**
 * 06 L 组 / V7 V8 的期望值,汇成一张表供 P1 的重放测试消费。
 *
 * ⚠ **T3 只把它写出来,没有任何东西在断言它** —— 断言需要 `ledger/fold.ts` 与
 * `sales fold`(P1-T2 / P1-T3),那时候才能做「删投影 → 全量重放 → 逐值相等」
 * 的 L5 等价检查。这是 T3 验收「seed 后重算投影与 fixture 期望一致」尚未兑现的那一半,
 * 已记入 CLAUDE.md 欠账。**今天能验的那一半**(store 层 UNIQUE 挡住重复投递)
 * 由 db/verify-schema.sh 断言,不是空话。
 */
export const EXPECTED = {
  ledgerSellable: Object.fromEntries(LEDGER_CASES.map((c) => [c.sku, c.expectedSellable])),
  dailyUnits: Object.fromEntries(SALES_CASES.map((c) => [c.sku, c.expectedBuckets])),
  stockoutDates: { [STOCKOUT_CASE.sku]: STOCKOUT_CASE.observedDates },
} as const
