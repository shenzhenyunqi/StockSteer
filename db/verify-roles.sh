#!/usr/bin/env bash
# P0-T2 验收 / 权限回归。两条串各连一次——身份不同,连接就必须不同;
# 且开头先自证这套断言可信(非 loopback、身份正确),再谈权限。
#   本地:  pnpm db:verify
#   CI  :  P0-T4 的 integration 段调同一份(07 §8「靠权限兜底,不靠纪律」的可执行兑现)
#
# 注:大部分断言只能用探针表,因为真实事件表要到 P0-T3 才存在。末尾那段「事件表」
# 断言是自激活的:三张表还不存在就 SKIP,T3 建表当天自己醒过来,不需要谁记得回来接线。
set -uo pipefail

# 主机名必须是 compose 服务名 `postgres`,**不能是 localhost**:官方镜像的 pg_hba.conf
# 有 `host all all 127.0.0.1/32 trust`,走 loopback 时口令完全不校验——口令全错
# 也能跑出 11/11 全绿,而应用/Prisma/CI 侧走的是 scram 那条路。服务名解析到
# bridge IP(非 loopback)=> 命中 `host all all all scram-sha-256`,凭据才真的被验。
MIG="${MIGRATOR_DATABASE_URL:-postgresql://migrator:${MIGRATOR_PASSWORD:-migrator}@postgres:5432/stocksteer}"
RUN="${DATABASE_URL:-postgresql://app_runtime:${APP_RUNTIME_PASSWORD:-app_runtime}@postgres:5432/stocksteer}"
PRG="${PURGER_DATABASE_URL:-postgresql://app_purger:${PURGER_PASSWORD:-app_purger}@postgres:5432/stocksteer}"

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=1; }
run() { psql "$1" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -tAqc "$2" 2>&1; }

expect_ok() { local out rc; out=$(run "$1" "$2"); rc=$?
  [ $rc -eq 0 ] && ok "$3" || bad "$3" "$out"; }
expect_denied() { local out rc; out=$(run "$1" "$2"); rc=$?
  if [ $rc -eq 0 ]; then bad "$3" "竟然成功了 -> $out"
  elif grep -q "42501" <<<"$out"; then ok "$3"   # 断 SQLSTATE,不断文本
  else bad "$3" "$out"; fi; }
expect_eq() { local out; out=$(run "$1" "$2")
  [ "$out" = "$3" ] && ok "$4" || bad "$4" "得到 [$out],期望 [$3]"; }

echo "· preflight(这套断言本身可不可信)"
# 上面那段注释挡不住 env 覆盖:MIGRATOR_DATABASE_URL / DATABASE_URL 会无条件胜出,
# 而 .env.example 里那两条串正是 @127.0.0.1 —— 谁 `set -a; . .env` 一下,
# 整份"证明"就静默退回 trust 通道。所以在库里自证,而不是在注释里叮嘱。
for pair in "MIG:$MIG:migrator" "RUN:$RUN:app_runtime" "PRG:$PRG:app_purger"; do
  tag=${pair%%:*}; rest=${pair#*:}; url=${rest%:*}; want=${rest##*:}
  expect_eq "$url" "select (inet_client_addr() is null
                         or inet_client_addr() <<= inet '127.0.0.0/8'
                         or inet_client_addr() <<= inet '::1/128')::text" \
    "false" "$tag 不走 loopback/socket(否则 pg_hba 的 trust 让口令形同虚设)"
  expect_eq "$url" "select current_user" "$want" "$tag 的身份确实是 $want"
done

run "$MIG" "DROP TABLE IF EXISTS _probe_child, _probe_parent, _probe_event, _probe_mutable CASCADE" >/dev/null

echo "· migrator(DDL 身份)"
expect_ok "$MIG" "CREATE TABLE _probe_event (id text primary key, qty int)" \
  "可以建表"

echo "· fail-closed 默认权限"
# 用 has_table_privilege 而非 information_schema:后者按 grantee 过滤,
# 看不见 `GRANT ... TO PUBLIC` 这种间接授予(实测会漏报)。TRUNCATE 必须在列——
# 它能一条语句抹平账本,却不被 UPDATE/DELETE 的断言覆盖,而 `GRANT ALL` 会把它带进来。
expect_eq "$RUN" \
  "select has_table_privilege('app_runtime','_probe_event','SELECT')::text||','||
          has_table_privilege('app_runtime','_probe_event','INSERT')::text||','||
          has_table_privilege('app_runtime','_probe_event','UPDATE')::text||','||
          has_table_privilege('app_runtime','_probe_event','DELETE')::text||','||
          has_table_privilege('app_runtime','_probe_event','TRUNCATE')::text" \
  "true,true,false,false,false" \
  "新建表天然只有 SELECT+INSERT,UPDATE/DELETE/TRUNCATE 全无(无需任何 REVOKE)"

echo "· app_runtime(运行时身份)在 append-only 表上"
expect_ok     "$RUN" "insert into _probe_event values ('e1', 10)"        "INSERT 放行"
expect_ok     "$RUN" "select count(*) from _probe_event"                 "SELECT 放行"
expect_denied "$RUN" "update _probe_event set qty=99 where id='e1'"      "UPDATE 被拒"
expect_denied "$RUN" "delete from _probe_event"                          "DELETE 被拒"
expect_denied "$RUN" "truncate _probe_event"                             "TRUNCATE 被拒"

echo "· 可变表路径(migration 显式放权后应当能改)"
expect_ok "$MIG" "CREATE TABLE _probe_mutable (id text primary key, qty int);
                  GRANT UPDATE, DELETE ON _probe_mutable TO app_runtime" "migrator 显式放权"
expect_ok "$RUN" "insert into _probe_mutable values ('m1', 1);
                  update _probe_mutable set qty=2;
                  delete from _probe_mutable"                            "UPDATE/DELETE 放行"

echo "· app_runtime 不能自己造后门"
expect_denied "$RUN" "create table _sneaky (id int)"                     "建表被拒"
expect_eq "$RUN" "select rolsuper::text from pg_roles where rolname=current_user" "false" \
  "不是超级用户(Railway 默认给超级用户串,此断言在生产同样要跑)"

echo "· 建表身份没走错"
expect_eq "$MIG" \
  "select count(*)::text from pg_tables where schemaname='public' and tableowner <> 'migrator'" \
  "0" \
  "public 下所有表的 owner 都是 migrator(否则默认权限不生效,app_runtime 会全盘无权)"

echo "· app_purger(30 天物理删除专用,拍板点⑥)"
# 它不出现在任何默认权限里 => 对每张新表天生一无所有,只有 migration 显式授予才有权力
expect_eq "$PRG" \
  "select has_table_privilege('app_purger','_probe_event','SELECT')::text||','||
          has_table_privilege('app_purger','_probe_event','INSERT')::text||','||
          has_table_privilege('app_purger','_probe_event','UPDATE')::text||','||
          has_table_privilege('app_purger','_probe_event','DELETE')::text" \
  "false,false,false,false" \
  "对新表天生一无所有(不吃默认权限)"
expect_eq "$PRG" "select rolsuper::text from pg_roles where rolname=current_user" "false" \
  "不是超级用户"
# T3 的写法:只给三张事件表 SELECT + DELETE
expect_ok "$MIG" "GRANT SELECT, DELETE ON _probe_event TO app_purger" "migrator 显式授予 SELECT+DELETE"
expect_denied "$PRG" "insert into _probe_event values ('p1', 1)"  "INSERT 被拒(它只负责删)"
expect_denied "$PRG" "update _probe_event set qty=1"              "UPDATE 被拒"
expect_ok     "$PRG" "delete from _probe_event"                   "DELETE 放行(30 天清理靠它)"
# 关键:授了 purger 不等于放松了 runtime
expect_denied "$RUN" "delete from _probe_event"                   "app_runtime 仍然删不动(边界没被稀释)"

echo "· 全局:没有任何表越过授予面(不依赖 T3 的表清单,现在就生效)"
# GRANT ALL 带进来的不止 TRUNCATE:PG 的 relacl 还含 REFERENCES(x) 与 TRIGGER(t)。
# 只要有 TRIGGER 权限,非 owner 也能建 BEFORE INSERT ... RETURN NULL 的触发器,
# 让账本静默丢写 —— 只查 UPDATE/DELETE/TRUNCATE 的断言看不见它。
# 本设计里任何一张表都不该有这三项(投影重算已裁决走 DELETE)。
GLOBAL_GRANTS="select count(*)::text from pg_class c join pg_namespace n on n.oid=c.relnamespace
                where n.nspname='public' and c.relkind in ('r','p')
                  and has_table_privilege('app_runtime', c.oid, 'TRUNCATE, REFERENCES, TRIGGER')"
expect_eq "$MIG" "$GLOBAL_GRANTS" "0" "无表持有 TRUNCATE/REFERENCES/TRIGGER(GRANT ALL 会当场响)"

# 外键级联能绕开权限:RI 触发器以**被引用表**的权限执行,不看调用者。
# 于是 app_runtime 对事件表没有 DELETE,却能靠 delete 父行把事件行级联抹掉。
# 这里按"谁没有 DELETE 谁就是 append-only"自动发现事件表,不需要维护清单。
CASCADE_GUARD="select count(*)::text from pg_constraint c
                 join pg_class t on t.oid=c.conrelid
                 join pg_namespace n on n.oid=t.relnamespace
                where c.contype='f' and n.nspname='public'
                  and not has_table_privilege('app_runtime', t.oid, 'DELETE')
                  and (c.confdeltype not in ('a','r') or c.confupdtype not in ('a','r'))"
expect_eq "$MIG" "$CASCADE_GUARD" "0" "无 append-only 表可被级联删除/改写"

# 上一条断言不能是空转的 —— 造一对真的级联外键,确认它会响
run "$MIG" "CREATE TABLE _probe_parent (id text primary key);
            GRANT UPDATE, DELETE ON _probe_parent TO app_runtime;
            CREATE TABLE _probe_child (id text primary key,
              pid text references _probe_parent(id) ON DELETE CASCADE)" >/dev/null
out=$(run "$MIG" "$CASCADE_GUARD")
[ "$out" = "1" ] && ok "上条断言非空转:造一个级联外键立刻被抓出" \
                 || bad "上条断言非空转" "造了级联外键却仍是 [$out]"
run "$MIG" "DROP TABLE IF EXISTS _probe_child, _probe_parent CASCADE" >/dev/null

echo "· 三张真实事件表(P0-T4 spec 点名要的那条;T3 建表当天自动生效)"
# 上面那条全局断言刻意**不含 UPDATE/DELETE** —— 约十九张可变表合法持有它们,一并查会
# 天天误报。代价是「三张事件表没有 UPDATE/DELETE」到此为止仍然没有任何东西在断言,
# 而那正是 00-README 一票否决项 4 与 01 §1 共同压着的那条线。
# TRUNCATE/REFERENCES/TRIGGER 也列上:给可变表批量放权时写成 `GRANT ALL` 会把它们
# 一并带进来,而写错一次表名,两道防线都不响。
# has_table_privilege 的多权限写法是**任一命中即 true**,所以期望值是 false。
# 用 to_regclass 判存在:返回 NULL 就 SKIP(今天的情形),不必等谁记得回来加这几行。
for t in inventory_events sales_events stockout_observations; do
  if [ "$(run "$MIG" "select (to_regclass('public.$t') is not null)::text")" != "true" ]; then
    printf '  SKIP  %s\n        表尚不存在(P0-T3 未落地),建表当天这条断言自动启用\n' "$t"
    continue
  fi
  expect_eq "$MIG" \
    "select has_table_privilege('app_runtime','public.$t','UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')::text" \
    "false" \
    "$t:app_runtime 无 UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER"
done

run "$MIG" "DROP TABLE IF EXISTS _probe_event, _probe_mutable CASCADE" >/dev/null
echo
[ $fail -eq 0 ] && echo "权限矩阵全过" || echo "有断言失败"
exit $fail
