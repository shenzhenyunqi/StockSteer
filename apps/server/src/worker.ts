// 后台进程(07 §1 同镜像双进程之二)。队列拓扑在 P3(BullMQ:shopify-webhooks /
// shopify-backfill / projection-rebuild / reconciliation),这里只把进程立起来:
// T5 要证明的是「同一镜像能以第二种角色部署并活着」,不是队列本身。
import { prisma } from './infra/db/client.js'

export async function startWorker(): Promise<void> {
  console.log('worker 已启动(队列在 P3 接入;当前只保持进程存活并守住启动自检)')

  // 没有队列就没有事件循环持有者,进程会立刻退出、被平台判成 crash loop。
  // 用一个空 interval 顶着 —— P3 接上 BullMQ 后删掉。
  const keepAlive = setInterval(() => {}, 60_000)

  const shutdown = async (signal: string) => {
    console.log(`收到 ${signal},开始优雅关闭`)
    clearInterval(keepAlive)
    await prisma.$disconnect()
    process.exit(0)
  }
  process.on('SIGTERM', () => void shutdown('SIGTERM'))
  process.on('SIGINT', () => void shutdown('SIGINT'))
}
