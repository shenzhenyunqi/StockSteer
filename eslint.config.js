import js from '@eslint/js'
import tseslint from 'typescript-eslint'

/** 规则 1:core 允许的运行时依赖只有三个纯计算库(p0 §0);相对路径不限 */
const CORE_ALLOWED_IMPORT = String.raw`^(\.|zod$|ulid$|decimal\.js$)`

/** 规则 4:平台词汇不越过连接器边界(08 §6);关键词近似,review 兜底 */
const PLATFORM_VOCAB = String.raw`(fulfillable|available|committed|AFN|MFN)`

const coreImportWhitelist = {
  selector: `ImportDeclaration[source.value!=/${CORE_ALLOWED_IMPORT}/]`,
  message: 'core 的运行时依赖只允许 zod / ulid / decimal.js(p0 §0):零 IO、零框架',
}

/** 测试文件例外:golden tests 按 07 §1 全在 packages/core,vitest 是开发依赖不是运行时依赖 */
const coreImportWhitelistTest = {
  selector: `ImportDeclaration[source.value!=/^(\\.|zod$|ulid$|decimal\\.js$|vitest$)/]`,
  message: 'core 测试的依赖只允许 zod / ulid / decimal.js / vitest(p0 §0)',
}

const platformVocabBan = [
  {
    selector: `Identifier[name=/${PLATFORM_VOCAB}/i]`,
    message: '平台词汇(fulfillable/available/committed/AFN/MFN)不得越过 acl/ 边界(08 §6)',
  },
  {
    selector: `Literal[value=/${PLATFORM_VOCAB}/i]`,
    message: '平台词汇(fulfillable/available/committed/AFN/MFN)不得越过 acl/ 边界(08 §6)',
  },
]

export default tseslint.config(
  { ignores: ['**/dist/**', '**/node_modules/**', '**/infra/prisma/generated/**'] },
  js.configs.recommended,
  tseslint.configs.recommended,

  // 规则 2:Prisma 只许出现在 apps/server/src/infra/(07 §1、08 §5)
  // Prisma 7 起生成的 client 不在 node_modules,而在源码树里(output 必填),
  // import 是相对路径而非 `@prisma/*`——故包名与路径两条都要拦。
  {
    files: ['**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['prisma', '@prisma/*', '@prisma/**', '.prisma/**'],
              message: 'Prisma 只活在 apps/server/src/infra/(07 §1、08 §5)',
            },
            {
              group: ['**/infra/prisma/**', '**/generated/prisma/**'],
              message:
                'Prisma 7 生成的 client 是源码树里的相对路径;只有 apps/server/src/infra/ 内可以 import(07 §1、08 §5)',
            },
          ],
        },
      ],
    },
  },
  {
    files: ['apps/server/src/infra/**/*.ts'],
    rules: { '@typescript-eslint/no-restricted-imports': 'off' },
  },

  // 规则 1:core import 白名单
  {
    files: ['packages/core/**/*.ts'],
    rules: { 'no-restricted-syntax': ['error', coreImportWhitelist] },
  },
  // 规则 4:core 除 acl/ 外禁平台词汇
  // (no-restricted-syntax 的选项不跨块合并,后块整体覆盖,故此处重列规则 1)
  {
    files: ['packages/core/**/*.ts'],
    ignores: ['packages/core/src/acl/**'],
    rules: { 'no-restricted-syntax': ['error', coreImportWhitelist, ...platformVocabBan] },
  },
  // core 的测试文件:放行 vitest。不开这个口子,P1 写下第一条 golden 断言时
  // lint 就红——而 lint 是 CI 四段之首、merge 硬门。
  {
    files: ['packages/core/**/*.test.ts'],
    ignores: ['packages/core/src/acl/**'],
    rules: { 'no-restricted-syntax': ['error', coreImportWhitelistTest, ...platformVocabBan] },
  },
  // acl/ 的测试要拿平台词汇当测试数据(它测的就是平台→领域的翻译)
  {
    files: ['packages/core/src/acl/**/*.test.ts'],
    rules: { 'no-restricted-syntax': ['error', coreImportWhitelistTest] },
  },

  // 规则 3:web 禁接口类型断言(09 §3)
  {
    files: ['apps/web/**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/consistent-type-assertions': ['error', { assertionStyle: 'never' }],
    },
  },
)
