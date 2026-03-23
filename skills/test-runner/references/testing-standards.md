# Testing Standards

## Coverage Thresholds

| Metric | Minimum | Target |
|--------|---------|--------|
| Statements | 80% | 90% |
| Branches | 75% | 85% |
| Functions | 80% | 90% |
| Lines | 80% | 90% |

## Test Structure

### Unit Tests
```
src/
  modules/
    auth/
      auth.service.ts
      __tests__/
        auth.service.test.ts
```

### Integration Tests
```
tests/
  integration/
    auth.integration.test.ts
    payment.integration.test.ts
```

### E2E Tests (Playwright)
```
e2e/
  auth/
    login.spec.ts
    register.spec.ts
  payment/
    checkout.spec.ts
```

## Test Naming Convention

```typescript
describe('AuthService', () => {
  describe('login', () => {
    it('should return JWT token for valid credentials', () => {});
    it('should throw UnauthorizedError for invalid password', () => {});
    it('should lock account after 5 failed attempts', () => {});
  });
});
```

Pattern: `should {expected behavior} when/for {condition}`

## E2E with Playwright — Best Practices

```typescript
// Use data-testid for selectors (not CSS classes)
await page.getByTestId('login-button').click();

// Use API to set up test state (faster than UI)
await request.post('/api/test/seed', { data: testFixture });

// Assert on visible text, not internal state
await expect(page.getByText('Welcome, Test User')).toBeVisible();

// Clean up after test
test.afterEach(async ({ request }) => {
  await request.post('/api/test/cleanup');
});
```

## Google Remote Debug + Web MCP Integration

When using Chrome Remote Debug for e2e:

```typescript
// playwright.remote.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  use: {
    connectOptions: {
      wsEndpoint: process.env.CHROME_WS_ENDPOINT || 'ws://localhost:9222',
    },
    trace: 'on-first-retry',
    video: 'on-first-retry',
  },
  reporter: [
    ['json', { outputFile: 'test-results/report.json' }],
    ['html', { open: 'never' }],
  ],
  retries: 1,
});
```

## Mocking Rules

- Mock external services (HTTP, database) in unit tests
- Use real database in integration tests (test database)
- Use real browser in e2e tests
- Never mock the module under test
- Prefer dependency injection over module mocking
