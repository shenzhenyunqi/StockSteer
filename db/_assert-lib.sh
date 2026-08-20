# 断言底座:连接串、断言原语、preflight。由 verify-roles.sh 与 verify-schema.sh 共用。
#
# 为什么抽出来而不是各抄一份:下面那段 preflight 是**这两份"证明"能不能被采信**的
# 全部依据。抄两份的必然结局是改一处漏一处,而漏掉的那一份会跑出满绿。
# 单独成文件也就意味着:改连接方式只有这一个地方能改。
#
# 用法(在容器内):  . /db/_assert-lib.sh ;  preflight ;  ...断言... ;  exit $(summary)

# 主机名必须是 compose 服务名 `postgres`,**不能是 localhost**:官方镜像的 pg_hba.conf
# 有 `host all all 127.0.0.1/32 trust`,走 loopback 时口令完全不校验——口令全错
# 也能跑出满绿,而应用/Prisma/CI 侧走的是 scram 那条路。服务名解析到
# bridge IP(非 loopback)=> 命中 `host all all all scram-sha-256`,凭据才真的被验。
MIG="${MIGRATOR_DATABASE_URL:-postgresql://migrator:${MIGRATOR_PASSWORD:-migrator}@postgres:5432/stocksteer}"
RUN="${DATABASE_URL:-postgresql://app_runtime:${APP_RUNTIME_PASSWORD:-app_runtime}@postgres:5432/stocksteer}"
PRG="${PURGER_DATABASE_URL:-postgresql://app_purger:${PURGER_PASSWORD:-app_purger}@postgres:5432/stocksteer}"

fail=0
passed=0
ok()  { passed=$((passed + 1)); printf '  PASS  %s\n' "$1"; }
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
# 断某条语句以指定 SQLSTATE 失败(23505 唯一冲突 / 23503 外键冲突 / 42501 权限)。
# 断 SQLSTATE 而不是断"失败了"——不然任何拼错的 SQL 都能冒充成"约束生效"。
expect_sqlstate() { local out rc; out=$(run "$1" "$2"); rc=$?
  if [ $rc -eq 0 ]; then bad "$4" "竟然成功了 -> $out"
  elif grep -q "$3" <<<"$out"; then ok "$4"
  else bad "$4" "期望 SQLSTATE $3,实际:$out"; fi; }

# 开头先自证这套断言可信(非 loopback、身份正确),再谈别的。
#
# 上面那段注释挡不住 env 覆盖:MIGRATOR_DATABASE_URL / DATABASE_URL 会无条件胜出,
# 而 .env.example 里那两条串正是 @127.0.0.1 —— 谁 `set -a; . .env` 一下,
# 整份"证明"就静默退回 trust 通道。所以在库里自证,而不是在注释里叮嘱。
preflight() {
  echo "· preflight(这套断言本身可不可信)"
  for pair in "MIG:$MIG:migrator" "RUN:$RUN:app_runtime" "PRG:$PRG:app_purger"; do
    tag=${pair%%:*}; rest=${pair#*:}; url=${rest%:*}; want=${rest##*:}
    expect_eq "$url" "select (inet_client_addr() is null
                           or inet_client_addr() <<= inet '127.0.0.0/8'
                           or inet_client_addr() <<= inet '::1/128')::text" \
      "false" "$tag 不走 loopback/socket(否则 pg_hba 的 trust 让口令形同虚设)"
    expect_eq "$url" "select current_user" "$want" "$tag 的身份确实是 $want"
  done
}

# 自己数,不靠谁在文档里维护一个数字(那种数字必然会漂,而且漂了没人看得出来)
summary() {
  echo
  [ $fail -eq 0 ] && echo "$1 全过($passed 条断言)" || echo "$1 有断言失败(通过 $passed 条)"
  return $fail
}
