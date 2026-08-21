// 运行时 Prisma client(**app_runtime 身份**)。进程级单例:连接池归它管,
// 每个消费者各建一个会把池数量乘以消费者个数。
//
// 连接串只从 DATABASE_URL 取,缺了就抛 —— 与 prisma.config.ts 的 env() 同一个
// 态度(p0 §0 坑③):Railway 的 preDeploy 继承 app service 的环境变量、没有
// per-command override,漏配必须当场炸,不能悄悄回落到平台注入的**超级用户**串上。
import { PrismaPg } from '@prisma/adapter-pg'
import { PrismaClient } from '../prisma/generated/client.js'

const connectionString = process.env.DATABASE_URL
if (!connectionString) {
  throw new Error('DATABASE_URL 未设置 —— 运行时必须以 app_runtime 身份连库(07 §8)')
}

export const prisma = new PrismaClient({ adapter: new PrismaPg({ connectionString }) })
