// 同一镜像双进程入口:node dist/main.js server | worker(07 §1)。
//
// 两个角色**共享同一次启动自检**:生产权限断言在这里跑、跑不过就不启动
// (fail-closed)。放在分派之前是有意的 —— worker 同样以 app_runtime 连库,
// 它绕过自检就等于自检只覆盖了一半的连接。
import { assertRuntimeIdentity } from './infra/db/assert-runtime-identity.js'
import { prisma } from './infra/db/client.js'
import { startServer } from './server.js'
import { startWorker } from './worker.js'

const ROLES = { server: startServer, worker: startWorker } as const
type Role = keyof typeof ROLES

const role = process.argv[2]
if (role !== 'server' && role !== 'worker') {
  console.error(`用法:node dist/main.js <server|worker>(收到:${role ?? '(空)'})`)
  process.exit(1)
}

try {
  await assertRuntimeIdentity(prisma)
} catch (err) {
  // 这里**不**打印连接串:错误信息会进平台日志,而日志比环境变量好读到得多
  console.error(err instanceof Error ? err.message : err)
  await prisma.$disconnect()
  process.exit(1)
}

await ROLES[role as Role]()
