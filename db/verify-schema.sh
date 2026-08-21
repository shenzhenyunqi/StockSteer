#!/usr/bin/env bash
# P0-T3 验收 / schema 回归。verify-roles.sh 证明的是「权限模型本身成立」(探针表),
# 本脚本证明的是「**这套真实的表**上,不变量真的下到了 DB」。两份都由 `pnpm db:verify`
# 跑,CI 的 integration 段同源。
#
# 覆盖:
#   A 三张真实事件表的活体权限(不是查 catalog,是真去写/删一遍)
#   B 可变表放权完整性 —— fail-closed 的**漏写探测器**
#   C app_purger 的授予面恰好是三张事件表,一张不多
#   D 全域外键都是 Restrict/NoAction(附非空转自证)
#   E 外键真的挡住了「删父行连坐事件行」这条绕过权限的路
#   F recommendation_cards 的 active-slot 部分唯一索引 + 列级 UPDATE
#   G 种子 fixture 在位、params 默认值 = 06 冻结的 v7.4
#   H 幂等键:**键形对不对**(2026-08-21 起 (tenant, source_ref),source 出键;
#     结构断言 + 跨通道去重活体样本)与**维度够不够**(一单多 line item / 三态归一
#     / 同日重复采样)
#
# **本脚本要求 migration 已 apply 且种子已跑**(`pnpm db:migrate && pnpm db:seed`)。
# 缺其一就直接红,不 SKIP —— 与 verify-roles.sh 里那几条自激活断言不同:
# 那些是"未来才存在的东西",这些是"现在就该在的东西",静默跳过等于假绿。
set -uo pipefail

. "$(dirname "$0")/_assert-lib.sh"

preflight

DEMO_TENANT='01K5SEEDTENANT000000000001'
LEDGER_TENANT='01K5SEEDTENANT000000000002'
DEMO_PRODUCT='01K5SEEDPRDCT0000000000001' # CNDL-AMB-8OZ

echo "· 前置:migration 与种子是否在位"
expect_eq "$MIG" \
  "select count(*)::text from information_schema.tables
    where table_schema='public'
      and table_name in ('inventory_events','sales_events','stockout_observations','recommendation_cards','params')" \
  "5" "schema v1 已 apply(缺表 => 先跑 pnpm db:migrate)"
expect_eq "$RUN" "select count(*)::text from tenants where id in ('$DEMO_TENANT','$LEDGER_TENANT')" \
  "2" "两个种子租户在位(缺 => 先跑 pnpm db:seed)"

# ---------------------------------------------------------------------------
echo "· A 三张真实事件表:活体权限(真去写一遍,不只是查 catalog)"
# catalog 断言(has_table_privilege)在 verify-roles.sh 里已有。这里补的是**行为**:
# 权限位对了但被别的机制(触发器、规则、RLS)绕过去,catalog 一样是绿的。
PROBE_DATE="date '2000-01-01'" # 远离 90 天窗口:万一清理失败也影响不到任何速度计算
run "$PRG" "delete from stockout_observations where date = $PROBE_DATE" >/dev/null

expect_ok "$RUN" \
  "insert into stockout_observations (id, tenant_id, product_id, channel, date)
   values ('01K5PROBESTKZER00000000001','$DEMO_TENANT','$DEMO_PRODUCT','DTC', $PROBE_DATE)" \
  "app_runtime 可以 INSERT(账本要能记账)"
expect_denied "$RUN" \
  "update stockout_observations set channel='FBA' where date = $PROBE_DATE" \
  "app_runtime 改不动(append-only)"
expect_denied "$RUN" "delete from stockout_observations where date = $PROBE_DATE" \
  "app_runtime 删不动(append-only)"
expect_ok "$PRG" "delete from stockout_observations where date = $PROBE_DATE" \
  "app_purger 删得动(30 天物理删除靠它)"
expect_eq "$MIG" "select count(*)::text from stockout_observations where date = $PROBE_DATE" "0" \
  "探针行已清干净(不给速度计算留脏数据)"

# ---------------------------------------------------------------------------
echo "· B 可变表放权完整性(fail-closed 的漏写探测器)"
# fail-closed 的失败形态是「那张表当场写不动」。问题是**得有人去写它才会响**,
# 而 P1/P2 才会去写。这条断言把它提前到今天:除了下面这份明确的例外名单,
# public 里的每一张表都必须同时有 UPDATE 和 DELETE。新加表忘了写 GRANT,这里当场红。
#
# 例外名单只有四类,每一类都有一句话的理由:
#   三张事件表 —— append-only,**没有**才是对的
#   recommendation_cards —— 08 §4 卡行不可变,只给列级 UPDATE(status),见 F
#   _prisma_migrations —— 迁移账本,运行时身份一无所有
MUTABLE_GAP="select coalesce(string_agg(c.relname, ',' order by c.relname), '')
               from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relkind='r'
                and c.relname not in ('inventory_events','sales_events','stockout_observations',
                                      'recommendation_cards','_prisma_migrations')
                and c.relname not like '\_probe%'
                and not (has_table_privilege('app_runtime', c.oid, 'UPDATE')
                     and has_table_privilege('app_runtime', c.oid, 'DELETE'))"
expect_eq "$MIG" "$MUTABLE_GAP" "" "每张可变表都拿到了 UPDATE+DELETE(漏写 GRANT 的表会列在这里)"

expect_eq "$MIG" \
  "select has_table_privilege('app_runtime','_prisma_migrations','SELECT, INSERT, UPDATE, DELETE')::text||','||
          has_table_privilege('app_purger','_prisma_migrations','SELECT, INSERT, UPDATE, DELETE')::text" \
  "false,false" "_prisma_migrations 对运行时/清理身份一无所有(不能伪造迁移记录)"

# ---------------------------------------------------------------------------
echo "· C app_purger 的授予面恰好是三张事件表"
# 「不得给它任何其它表的任何权限」(T3 spec)。反过来查:它有权的表列出来,
# 必须一字不差就是这三张 —— 多一张少一张都红。
expect_eq "$MIG" \
  "select coalesce(string_agg(c.relname, ',' order by c.relname), '')
     from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relname not like '\_probe%'
      and (has_table_privilege('app_purger', c.oid,
             'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
        or has_any_column_privilege('app_purger', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))" \
  "inventory_events,sales_events,stockout_observations" \
  "app_purger 有权的表 = 三张事件表,一张不多"

# ---------------------------------------------------------------------------
echo "· D 全域外键都是 Restrict/NoAction"
# verify-roles.sh 那条只查「app_runtime 没有 DELETE 的表」上的外键(自动发现 append-only)。
# 这一条更宽:schema.prisma 的硬约束②是**每一条**外键都写死 Restrict/NoAction ——
# Prisma 对必填关系的默认是 onUpdate: Cascade、对可选关系是 onDelete: SetNull,
# 两个默认都会悄悄溜进来(新写一个 model 忘了写 @relation 参数就是了)。
FK_GUARD="select count(*)::text from pg_constraint c
            join pg_class t on t.oid=c.conrelid
            join pg_namespace n on n.oid=t.relnamespace
           where c.contype='f' and n.nspname='public' and t.relname not like '\_probe%'
             and (c.confdeltype not in ('a','r') or c.confupdtype not in ('a','r'))"
expect_eq "$MIG" "$FK_GUARD" "0" "public 下没有任何 CASCADE/SET NULL/SET DEFAULT 外键"
# 非空转自证
run "$MIG" "DROP TABLE IF EXISTS _probe_fk_child, _probe_fk_parent CASCADE;
            CREATE TABLE _probe_fk_parent (id text primary key);
            CREATE TABLE _probe_fk_child (id text primary key,
              pid text references _probe_fk_parent(id) ON UPDATE CASCADE)" >/dev/null
FK_GUARD_PROBE=${FK_GUARD//t.relname not like \'\\_probe%\'/true}
out=$(run "$MIG" "$FK_GUARD_PROBE")
[ "$out" = "1" ] && ok "上条断言非空转:造一个 ON UPDATE CASCADE 立刻被抓出" \
                 || bad "上条断言非空转" "造了级联外键却仍是 [$out]"
run "$MIG" "DROP TABLE IF EXISTS _probe_fk_child, _probe_fk_parent CASCADE" >/dev/null

# ---------------------------------------------------------------------------
echo "· E 外键真的挡住了「删父行连坐事件行」"
# 这是 p0 §0 第三轮复核的 B3:RI 触发器以**被引用表**的权限执行、不看调用者。
# app_runtime 对 inventory_events 没有 DELETE,但只要外键是 CASCADE,
# 一句 `delete from tenants` 就能把事件行抹掉。上面 D 查的是元数据,这里查行为。
expect_sqlstate "$RUN" "delete from tenants where id='$DEMO_TENANT'" "23503" \
  "删租户被外键挡下(23503),事件行没有被连坐"
expect_eq "$MIG" "select (count(*) > 0)::text from inventory_events where tenant_id='$DEMO_TENANT'" \
  "true" "事件行确实还在"

# ---------------------------------------------------------------------------
echo "· F recommendation_cards:active-slot 唯一 + 卡行不可变"
RUN_ID='01K5PROBERUN00000000000001'
C1='01K5PROBECARD0000000000001'
C2='01K5PROBECARD0000000000002'
C3='01K5PROBECARD0000000000003'
C4='01K5PROBECARD0000000000004'
cleanup_cards() {
  run "$RUN" "delete from recommendation_cards where id in ('$C1','$C2','$C3','$C4');
              delete from engine_runs where id='$RUN_ID'" >/dev/null
}
cleanup_cards
run "$RUN" "insert into engine_runs (id, tenant_id, date, card_count, duration_ms, gates)
            values ('$RUN_ID','$DEMO_TENANT', date '2000-01-01', 0, 0, '{}'::jsonb)" >/dev/null

card_sql() { # $1=id $2=type $3=dest(NULL 或 'FBA')$4=status
  echo "insert into recommendation_cards (id, tenant_id, run_id, product_id, card_type, dest_channel, explain, status)
        values ('$1','$DEMO_TENANT','$RUN_ID','$DEMO_PRODUCT','$2'::\"CardType\", $3, '{}'::jsonb, '$4'::\"CardStatus\")"
}

expect_ok "$RUN" "$(card_sql "$C1" MOVE_STOCK "'FBA'::\"Channel\"" active)" "第一张 active MOVE_STOCK→FBA 卡"
expect_sqlstate "$RUN" "$(card_sql "$C2" MOVE_STOCK "'FBA'::\"Channel\"" active)" "23505" \
  "同 slot 第二张 active 卡被唯一索引拒(08 §4:一个 slot 至多一张 active)"
# dest_channel 为空的那条路:PG 的唯一索引里 NULL 彼此不相等,所以必须另有一条索引兜住,
# 否则 SHARED_POOL 卡可以无限重复出。这条断言就是防止那条索引哪天被"简化"掉。
expect_ok "$RUN" "$(card_sql "$C3" SHARED_POOL NULL active)" "第一张 active SHARED_POOL 卡(dest 为空)"
expect_sqlstate "$RUN" "$(card_sql "$C4" SHARED_POOL NULL active)" "23505" \
  "dest 为空时同 slot 第二张也被拒(NULL 不会各算各的)"

# 「部分」必须是真的部分:卡退出 active 后,同 slot 应当能再出新卡(次日 superseded 语义)
expect_ok "$RUN" "update recommendation_cards set status='superseded' where id='$C1'" \
  "列级 UPDATE(status) 放行 —— 状态迁移是唯一允许的写"
expect_denied "$RUN" "update recommendation_cards set qty=99 where id='$C1'" \
  "改 qty 被拒(08 §4 卡行不可变,列级授权把它下到了 DB)"
expect_denied "$RUN" "update recommendation_cards set explain='{}'::jsonb where id='$C1'" \
  "改 explain 被拒(已出卡保留其计算时假设)"
expect_ok "$RUN" "$(card_sql "$C2" MOVE_STOCK "'FBA'::\"Channel\"" active)" \
  "旧卡不再 active 后同 slot 可再出卡(证明索引是部分的,不是全表唯一)"
cleanup_cards

# ---------------------------------------------------------------------------
echo "· G 种子 fixture 与 v7.4 默认参数"
expect_eq "$RUN" "select timezone from tenants where id='$DEMO_TENANT'" "America/Los_Angeles" \
  "demo 租户时区 = 店铺时区(01 §1 归日基准)"
# **拿 ledger 租户比,不是 demo 租户**:那一行是种子一个值都没传建出来的,所以比的
# 就是 DB 默认值本身。demo 租户按 02 §8「demo 用 512」额外播了账号健康,拿它比会
# 把"默认无 IPI"这条断言弄脏 —— 两个需求各用一个租户,互不打架。
# golden 用的是 in-code 常量,默认值哪天漂了它看不见 —— 这条能看见(06 冻结的 v7.4)。
expect_eq "$RUN" \
  "select cover_days||'/'||safety_days||'/'||lead_days||'/'||ceiling_days||'/'||
          velocity_window_days||'/'||velocity_weighting||'/'||exclude_stockout_days||'/'||apply_promo||'/'||
          round_up_to_case||'/'||min_move_qty||'/'||move_priority||'/'||
          self_ship_cost_per_order||'/'||mcf_enabled||'/'||mcf_fee_per_order||'/'||removal_fee_per_unit||'/'||
          alert_lead_days||'/'||coalesce(ipi_score::text,'-')||'/'||coalesce(inbound_limit_remaining::text,'-')
     from params where tenant_id='$LEDGER_TENANT'" \
  "35/14/7/60/90/even/true/true/true/24/margin_first/6.90/true/5.87/0.97/10/-/-" \
  "params 的 DB 默认值逐字 = 06 冻结的 v7.4(IPI 与入库限额确实无默认)"

# L1 的下半句「第二次静默丢弃」—— store 层 UNIQUE 是第一道(P1-T2)。
# fold 那一道等 P1-T2,但**这一道今天就能验**,且它不是空转:种子真的投了两次。
expect_eq "$RUN" \
  "select count(*)::text from inventory_events e join products p on p.id=e.product_id
    where p.display_sku='LEDGER-L1-IDEMPOTENT'" \
  "1" "L1:同 source_ref 投递两次,库里只有一条"
expect_eq "$RUN" \
  "select count(*)::text from sales_events e join products p on p.id=e.product_id
    where p.display_sku='LEDGER-V8-CANCELLATION'" \
  "2" "V8:sale + cancellation 各一条,重复投递的那条被丢弃"
# demo 侧的销售件数 = fixture 声明的 v × 90(even 加权下速度就是这么来的)
expect_eq "$RUN" \
  "select string_agg(s, ',' order by s) from (
     select p.display_sku||':'||e.channel||'='||sum(e.qty)::text as s
       from sales_events e join products p on p.id=e.product_id
      where e.tenant_id='$DEMO_TENANT'
      group by p.display_sku, e.channel) t" \
  "CNDL-AMB-8OZ:DTC=630,CNDL-AMB-8OZ:FBA=783,CNDL-VNL-8OZ:DTC=288,CNDL-VNL-8OZ:FBA=459,DIFF-RD-100ML:DTC=216,DIFF-RD-100ML:FBA=369,SOAP-LAV-3PK:DTC=351,SOAP-LAV-3PK:FBM=225" \
  "demo 销售流件数逐条对上(= 06 给的 v × 90 天)"

expect_eq "$RUN" \
  "select coalesce(ipi_score::text,'-')||'/'||coalesce(to_char(ipi_entered_at at time zone 'America/Los_Angeles','YYYY-MM-DD'),'-')
     from params where tenant_id='$DEMO_TENANT'" \
  "512/2026-08-12" \
  "demo 租户账号健康 = 06 冻结的 IPI 512 / entered Aug 12(G1 归因行要逐字复现它)"

# ---------------------------------------------------------------------------
echo "· H 幂等键:键形与维度(2026-08-20 维度 BLOCKER + 2026-08-21 键形裁决的回归位)"
# 幂等键是 (tenant, source_ref)(2026-08-21 裁决:source 出键,否则同一平台事实经
# webhook 与 bulk 两条通道到达无法互相去重,回填期间双计)。01 §1 规定重复投递
# **静默丢弃**,于是「source_ref 少带一个维度」的失败形态不是报错,是**无声少记**,
# 且事件表 append-only、少记的行没有重放面。2026-08-20 的原 spec 有两处踩了维度坑:
#   ① p3 的 webhook 约定是整条 webhook 一个 id,而一单 N 个 line item → N 行 sales_events
#   ② p6 的 snapshot 约定是 {reportId}:{sku},而 01 §3 三态归一 → 一条记录 3 条事件
# 种子按现行约定播了活体样本,这里断言:键形真的换了(结构 + 行为)、维度都进得去。

# 键形·结构:两张事件表的唯一索引恰是 (tenant_id, source_ref) —— 不含 source
expect_eq "$MIG" \
  "select count(*)::text from pg_indexes
    where schemaname='public' and tablename in ('inventory_events','sales_events')
      and indexdef like '%UNIQUE%' and indexdef like '%(tenant_id, source_ref)%'" \
  "2" "幂等键键形 = (tenant_id, source_ref):两张事件表各一条唯一索引,source 不在其中"
expect_eq "$MIG" \
  "select count(*)::text from pg_indexes
    where schemaname='public' and tablename in ('inventory_events','sales_events')
      and indexdef like '%UNIQUE%' and indexdef like '%source,%'" \
  "0" "旧键形 (tenant, source, source_ref) 的唯一索引已不存在"

# 键形·行为:XS 样本 —— 同一平台记录身份(同 source_ref)经 webhook 与 bulk 两条
# 通道投递,库里只有一条。旧键形下 source 不同不撞键,这里会数出 2(且 seed.ts 的
# 「重复投递必须全部被丢弃」断言在种子阶段就会先炸)。L1 那种同 source 重复在
# 两种键形下都会被丢,证不了索引换没换 —— 这条才是键形裁决的活体证明。
expect_eq "$RUN" \
  "select count(*)::text||'/'||sum(e.qty)::text
     from sales_events e join products p on p.id=e.product_id
    where p.display_sku='LEDGER-XS-CROSSSOURCE'" \
  "1/2" \
  "XS:跨通道重复投递被丢弃(webhook 那条在、bulk 那条被 UNIQUE 吸收,qty=2 而非 999)"
expect_eq "$RUN" \
  "select count(*)::text||'/'||count(distinct e.order_ref)::text||'/'||sum(e.qty)::text
     from sales_events e join products p on p.id=e.product_id
    where p.display_sku='LEDGER-ML-MULTILINE'" \
  "2/1/5" \
  "一单两个 line item(同 SKU)两行都在:少带 lineItem 维度会掉成 1 行"
expect_eq "$RUN" \
  "select count(*)::text from inventory_events e join products p on p.id=e.product_id
    where p.display_sku='CNDL-AMB-8OZ' and e.channel='FBA'" \
  "3" \
  "FBA 一条库存记录归一出 sellable/reserved/inbound 三行:少带 state 维度会掉成 1 行"
# 测试订单:入库 + 标记(p0 §0 裁决),不是在 ACL 丢弃
expect_eq "$RUN" \
  "select count(*)::text||'/'||count(*) filter (where e.excluded_reason is not null)::text
     from sales_events e join products p on p.id=e.product_id
    where p.display_sku='LEDGER-TEST-ORDER'" \
  "2/1" \
  "测试订单入了库并被标记(excluded_reason),不是被丢掉"
# V6:断货日自观测。8/15 记、8/16 不记(白天闪断不算),同日重复采样被唯一键丢弃
expect_eq "$RUN" \
  "select coalesce(string_agg(to_char(o.date,'YYYY-MM-DD'), ',' order by o.date), '')
     from stockout_observations o join products p on p.id=o.product_id
    where p.display_sku='LEDGER-V6-STOCKOUT'" \
  "2026-08-15" \
  "V6:只有 8/15 一行(8/16 白天闪断不记;同日重复采样被 UNIQUE 丢弃)"

# ⚠ T3 验收「seed 后重算投影与 fixture 期望一致」的**另一半在此缺席**:
# 重算需要 ledger/fold.ts(P1-T2)与 sales fold(P1-T3),今天树里没有。
# 期望值已经落在 apps/server/src/infra/seed/fixture.ts 的 EXPECTED 里,
# P1-T2 落地当天补一条「删投影 → 全量重放 → 逐值相等」的集成测试(L5)。
# 这里不假装验过。

summary "schema 不变量"
exit $?
