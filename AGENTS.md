# Rules for Zlox Project

## Project Overview
**zlox** is a Zig implementation of the Lox programming language from [Crafting Interpreters book](https://craftinginterpreters.com/), with only bytecode virtual machine implemented.

## Code Style Guidelines
- Follow Zig standard library conventions
- Use snake_case for functions and variables
- Use PascalCase for types and structs
- Use SCREAMING_SNAKE_CASE for constants
- Prefer explicit error handling with `!` return types
- Keep functions small and focused on single responsibility

## Development Rules

### Before Making Changes
1. Read existing code to understand patterns and conventions
2. Check for existing tests related to modified functionality
3. Ensure changes are compatible with existing API

### When Writing Code
1. Write idiomatic Zig code following std lib patterns
2. Handle all errors explicitly - no silent failures
3. Add tests for new functionality
4. Keep backward compatibility when possible

### When Fixing Bugs
1. Understand root cause before fixing
2. Add regression test if missing
3. Check for similar issues in related code
4. Verify fix doesn't break existing tests

## Build & Test Commands
```bash
# Build
just build Debug

# Run tests
just test Debug

# Build release
just build
```

## Important Notes
- Always verify build passes before completing tasks
- Run full test suite after significant changes
- Follow existing code organization patterns
- Write code comments only in English
- Don't write trivial code comments
- Write tests in AAA pattern - Arange, Act, Assert
- Always apply zig fmt to final result
