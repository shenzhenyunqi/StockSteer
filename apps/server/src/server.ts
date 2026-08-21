// HTTP 进程(07 §1 同镜像双进程之一)。T5 只要 /healthz;路由与 SPA 托管在 P4。
import Fastify from 'fastify'
import { prisma } from './infra/db/client.js'

export async function startServer(): Promise<void> {
  const app = Fastify({ logger: true })

  // Railway 注入 PORT;本地缺省 8080。**必须听 0.0.0.0** —— 默认的 localhost
  // 在容器里只听回环,平台的健康检查从外面打进来会全部超时。
  const port = Number(process.env.PORT ?? 8080)

  // 只报「进程活着」,**不查库**(07 §5:健康检查不做级联判定)。库的可用性由
  // 启动自检与 Watchdog 负责;把 DB 查询放进 healthz 会让一次库抖动直接变成
  // 平台重启进程,把小故障放大成停服。
  app.get('/healthz', async () => ({ ok: true }))

  await app.listen({ port, host: '0.0.0.0' })

  const shutdown = async (signal: string) => {
    app.log.info({ signal }, '收到停止信号,开始优雅关闭')
    await app.close()
    await prisma.$disconnect()
    process.exit(0)
  }
  process.on('SIGTERM', () => void shutdown('SIGTERM'))
  process.on('SIGINT', () => void shutdown('SIGINT'))
}
