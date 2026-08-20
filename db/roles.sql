-- P0-T2 · DB 双角色(07 §8)
--   app_runtime -- 运行时身份。默认只拿 SELECT + INSERT
--   migrator    -- DDL 身份,schema 的 owner
--   app_purger  -- 30 天物理删除专用(拍板点⑥,2026-08-20 裁决:身份即边界)。
--                  全部权力 = 对三张事件表的 SELECT + DELETE,由 T3 的 migration 显式授予;
--                  **不设任何默认权限**,故对其它表天生一无所有。purge job 的其余步骤
--                  (可变表)仍以 app_runtime 跑,只有删事件行那一步换这条串。
--
-- **幂等**:可重复执行。本地由 db/init/01-roles.sh 在 initdb 阶段调用;
-- Railway 等托管 PG 没有 init 钩子(默认还直接给超级用户串),同一份脚本
-- 手工或 pre-deploy 跑一次即可 —— 兜底不依赖某个平台的初始化机制(P0-T5)。
--
-- 口令由调用方传:psql -v migrator_pw=... -v runtime_pw=...
--
-- 首行自设 ON_ERROR_STOP:否则 psql 报错后会继续往下跑并以 0 退出,守卫等于没有
-- (官方:"processing continues after an error" 除非置位)。手工/Railway 路径正是
-- 守卫唯一存在的理由,而它恰好在那条路径上失效——所以由脚本自己兜,不靠调用方记得。
\set ON_ERROR_STOP on

-- 缺参守卫:必须在建任何东西之前失败,否则会留下"角色已建但口令为 NULL"的半套状态
\if :{?migrator_pw} \else \set migrator_pw '' \endif
\if :{?runtime_pw}  \else \set runtime_pw  '' \endif
-- 缺参守卫。两处坑:psql **不在 $$...$$ 内插值变量**(故不能直接写 :'migrator_pw'),
-- 而普通 SQL 里拿常量做 CAST 会被**常量折叠**、在计划期就报错(CASE 短路救不了)。
-- 走 GUC 传值即可两头避开。配合 ON_ERROR_STOP + --single-transaction => 整套回滚,
-- 不留"角色已建但口令为 NULL"的半套状态。
-- 目标库守卫:角色是 cluster 级,而 ALTER SCHEMA OWNER 与 ALTER DEFAULT PRIVILEGES
-- 是 per-database(pg_default_acl 存在每个库里)。跑错库会"角色建了、权限没落地"。
\if :{?expect_db} \else \set expect_db '' \endif
SET app.expect_db = :'expect_db';
DO $$
BEGIN
  IF current_setting('app.expect_db') <> '' AND current_setting('app.expect_db') <> current_database() THEN
    RAISE EXCEPTION 'roles.sql 跑错库了:当前 %,期望 %', current_database(), current_setting('app.expect_db');
  END IF;
END
$$;

\if :{?purger_pw} \else \set purger_pw '' \endif
SET app.purger_pw = :'purger_pw';
SET app.migrator_pw = :'migrator_pw';
SET app.runtime_pw  = :'runtime_pw';
DO $$
BEGIN
  IF current_setting('app.migrator_pw') = '' OR current_setting('app.runtime_pw') = ''
     OR current_setting('app.purger_pw') = '' THEN
    RAISE EXCEPTION 'roles.sql 必须传 -v migrator_pw=... -v runtime_pw=... -v purger_pw=...';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'migrator') THEN
    CREATE ROLE migrator LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_runtime') THEN
    CREATE ROLE app_runtime LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_purger') THEN
    CREATE ROLE app_purger LOGIN;
  END IF;
END
$$;

-- CREATEDB 是 `prisma migrate dev` 的硬前提:它要建/删 shadow database
-- (Prisma 官方:"requires that the database user ... has permission to create databases",
--  否则 P3014)。生产只跑 migrate deploy,不需要 shadow db,但同一份脚本共用无害。
-- 显式写全否定属性:上面的 IF NOT EXISTS 会跳过已存在的角色,
-- 若集群里预先有个同名 superuser,不写这些它会原样活下来(verify 的 rolsuper
-- 断言只查运行时身份,查不到 migrator)。
ALTER ROLE migrator    WITH LOGIN CREATEDB   NOCREATEROLE NOSUPERUSER NOREPLICATION NOBYPASSRLS PASSWORD :'migrator_pw';
ALTER ROLE app_runtime WITH LOGIN NOCREATEDB NOCREATEROLE NOSUPERUSER NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_pw';
ALTER ROLE app_purger  WITH LOGIN NOCREATEDB NOCREATEROLE NOSUPERUSER NOREPLICATION NOBYPASSRLS PASSWORD :'purger_pw';

-- schema 归 migrator => 一切 DDL 只可能出自 migrator;app_runtime 建不了表
ALTER SCHEMA public OWNER TO migrator;

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO migrator, app_runtime, app_purger', current_database());
END
$$;

-- REVOKE ALL 而不只是 USAGE:PG15 起"PUBLIC 无 CREATE"是**新建集群**的默认,
-- 官方明写 pg_upgrade / dump-restore 会保留旧的 public 权限——托管 PG 上不能假定。
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO app_runtime, app_purger;

-- ===== fail-closed:默认权限只有 SELECT + INSERT =====
-- migrator 今后建的表,app_runtime **天然是 append-only**。
-- 可变表(投影/products/params/cards/...)在各自 migration 里显式
--   GRANT UPDATE, DELETE ON <表> TO app_runtime;
-- 漏写的后果 = 那张表当场写不动、开发或 CI 立刻报错;
-- 而不是"漏写一次就静默失去 append-only 不变量"(07 §8:靠权限兜底,不靠纪律)。
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  GRANT SELECT, INSERT ON TABLES TO app_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_runtime;
-- 函数默认 EXECUTE 是给 PUBLIC 的,而 ON TABLES 的默认权限对它零作用。
-- 不收掉的话,任何 SECURITY DEFINER 函数都是绕过整套权限模型的现成通道。
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- app_purger **刻意不出现在任何默认权限里**:它对每一张新表天生一无所有,
-- 只有 T3 的 migration 显式给三张事件表 GRANT SELECT, DELETE 才有权力。
