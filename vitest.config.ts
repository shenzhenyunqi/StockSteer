import { defineConfig } from 'vitest/config'

// 07 §7 / P0-T4:CI 四段中 unit 与 integration 分开跑
export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          environment: 'node',
          include: ['packages/*/src/**/*.test.ts', 'tools/*/src/**/*.test.ts'],
        },
      },
      {
        test: {
          name: 'integration',
          environment: 'node',
          include: ['apps/server/src/**/*.integration.test.ts'],
        },
      },
    ],
  },
})
