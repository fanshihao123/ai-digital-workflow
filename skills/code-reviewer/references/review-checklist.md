# Code Review Checklist

## 1. Code Quality

### CQ-001: Naming Conventions
- Variables/functions use camelCase (TypeScript) or snake_case (Python)
- Classes/types use PascalCase
- Constants use UPPER_SNAKE_CASE
- Names are descriptive and intention-revealing
- No single-letter variables except loop counters

### CQ-002: Function Design
- Functions do one thing (Single Responsibility)
- Functions are < 30 lines (ideally < 20)
- Maximum 3 parameters (use options object for more)
- No side effects in pure functions
- Early returns for guard clauses

### CQ-003: Error Handling
- All async operations have proper error handling
- Errors are typed (not generic catch-all)
- Error messages are actionable and specific
- No swallowed errors (empty catch blocks)
- Proper HTTP status codes for API errors

### CQ-004: Code Duplication
- No copy-pasted code blocks (DRY)
- Shared logic extracted to utilities
- Common patterns abstracted appropriately

## 2. Security

### SEC-001: Input Validation
- All user inputs are validated and sanitized
- SQL parameters are parameterized (no string concatenation)
- HTML output is escaped to prevent XSS
- File uploads have type and size validation

### SEC-002: Authentication & Authorization
- Endpoints have proper auth guards
- Role-based access is enforced
- Tokens are not logged or exposed
- Session management follows SECURITY.md patterns

### SEC-003: Data Protection
- PII is not logged
- Sensitive data is encrypted at rest
- API responses don't leak internal details
- CORS is properly configured

### SEC-004: Dependency Security
- No known vulnerable dependencies
- Dependencies are pinned to specific versions
- No unnecessary permissions requested

## 3. Performance

### PERF-001: Database
- No N+1 query patterns
- Queries use appropriate indexes
- Pagination for list endpoints
- No SELECT * in production code

### PERF-002: Memory & Resources
- No memory leaks (event listeners cleaned up)
- Streams used for large data
- Connections properly closed
- Caching applied where appropriate

### PERF-003: API Design
- Response payloads are minimal
- Compression enabled for large responses
- Rate limiting in place for public APIs

## 4. Architecture

### ARCH-001: Module Boundaries
- No cross-module imports that violate ARCHITECTURE.md
- Dependencies flow in the correct direction
- Shared types are in shared module

### ARCH-002: Separation of Concerns
- Business logic separated from presentation
- Data access layer abstracted
- Configuration externalized

## 5. Testing

### TEST-001: Coverage
- New code has unit tests
- Edge cases are covered
- Error paths are tested

### TEST-002: Test Quality
- Tests are independent (no shared state)
- Assertions are specific (not just "truthy")
- Mocks are minimal and focused

## Severity Definitions

- **CRITICAL**: Security vulnerability, data loss risk, or production crash → Must fix before merge
- **ERROR**: Bug, logic error, or standards violation → Should fix before merge
- **WARNING**: Code smell, minor improvement → Consider fixing
- **INFO**: Style suggestion, optional improvement → Nice to have
