# Testing Guardrails for Ralph

_Add these rules to your project-context file to prevent common dev-agent testing failures. Ralph receives project-context as ambient context on every story execution._

_These rules were extracted from production use where Ralph produced tests that passed but didn't actually test anything — reading source files as strings, wrapping assertions in conditionals, using vacuous expectations, and inventing workaround patterns when test libraries were missing._

---

## Test Behavioral Validity (BLOCKING — dev agent must halt on violation)

Tests must exercise code by **importing and calling it**, not by reading source files as strings. A test that passes when the source file is empty is not a test.

**Anti-patterns (NEVER use — fix if found in existing code):**
- `readFileSync`/`fs` imports in test files to inspect source code
- Conditional guards around assertions (`if (await el.isVisible()) { expect... }`)
- Vacuous assertions that cannot fail (`toBeGreaterThanOrEqual(0)`)
- Empty test bodies (zero `expect()` calls)
- Unit tests that don't import from `src/` (the code under test)

**Required patterns:**
- Component tests: `render()` + `screen` queries from `@testing-library/svelte` (or your framework's testing-library)
- Function tests: import function, call with inputs, assert outputs
- E2E tests: every `test()` block must have unconditional `expect()` assertions
- If a test dependency is missing: **install it** (`npm install -D`), never invent workarounds

## Testing Gotchas

_Framework-specific gotchas to include if applicable to your stack._

### Vitest + SvelteKit
- Add `deps.inline: ['@sveltejs/kit']` for `$app/*` imports
- Vitest 4 mock changes: `vi.fn().getMockName()` returns `vi.fn()` not `spy`; `vi.restoreAllMocks` only restores `vi.spyOn` spies

### Playwright + SvelteKit
- Wait for hydration before interacting — forms clear if Playwright acts before hydration completes

### General
- If a test library is missing from devDependencies, the dev agent MUST install it before writing tests — never invent a workaround pattern (e.g., reading files with `fs` instead of using `@testing-library`)
- Never write `if (visible) { assert }` — tests must assert unconditionally. A test that can skip its assertions is not a test.

---

## How to Use

Add these rules to your `project-context.md` (or whatever file you configured as `PROJECT_CONTEXT` during install). Ralph receives this file as ambient system-prompt context on every story execution.

For BMAD projects:
```
_bmad-output/planning-artifacts/project-context.md
```

For generic projects, create a `project-context.md` at your configured path and include these rules alongside your project's coding standards, naming conventions, and framework patterns.

### Why This Matters

Dev agents (LLMs executing code) have a strong tendency to produce tests that "look right" but don't actually test behavior. Common failure modes:

1. **String reading** — Agent reads source code as a string and asserts it contains certain patterns. These tests pass even if the code doesn't work.
2. **Conditional assertions** — Agent wraps `expect()` in `if (element.isVisible())`. If the element isn't visible (bug), the test silently passes.
3. **Vacuous assertions** — Agent writes `expect(count).toBeGreaterThanOrEqual(0)`. This literally cannot fail.
4. **Missing library workarounds** — Agent can't find `@testing-library/svelte` and invents a pattern using `fs.readFileSync` to read the component source instead.

These rules make it explicit: if you hit a wall, install the dependency. If you can't assert unconditionally, the feature is broken. If your test passes with an empty source file, your test is broken.
