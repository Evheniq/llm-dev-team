# Code Style Guide

## Naming
- Use camelCase for variables, PascalCase for exported types
- Acronyms: keep consistent casing (URL, HTTP, ID — not Url, Http, Id)

## Error Handling
- Always wrap errors with context: `fmt.Errorf("operation: %w", err)`
- Never swallow errors silently
- Use sentinel errors for expected conditions

## Structure
- One package per domain concept
- Keep files under 300 lines
- Group related functions together

## Comments
- Only where logic is non-obvious
- No redundant comments (e.g., `// GetUser gets user`)

(customize this file for your project's standards)
