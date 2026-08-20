#!/bin/bash
# docker-entrypoint-initdb.d 钩子:**只在数据卷首次初始化时**执行一次
# (官方:scripts are only run if you start the container with an empty data directory)。
# => 改了 db/roles.sql 之后,本地必须 `pnpm db:reset` 重建卷才会生效。
# 本文件是 755,entrypoint 走 exec 分支(日志里是 `running`,不是 `sourcing`),
# 所以 set 选项本不会外溢。仍不用 -u:万一哪天 exec 位丢了就变成 source 路径,
# 而 entrypoint 自己只 set -Eeo pipefail。口令都有默认值,-u 在这里也不买什么。
set -eo pipefail

# --single-transaction:roles.sql 全是可事务化语句,要么整套成立要么什么都不留
psql -v ON_ERROR_STOP=1 --single-transaction --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v migrator_pw="${MIGRATOR_PASSWORD:-migrator}" \
  -v runtime_pw="${APP_RUNTIME_PASSWORD:-app_runtime}" \
  -v purger_pw="${PURGER_PASSWORD:-app_purger}" \
  -v expect_db="$POSTGRES_DB" \
  -f /db/roles.sql
