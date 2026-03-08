# Context Files

Project-specific files that are injected into agent prompts.

## Naming Convention

Agent targets are specified in the filename before the extension:

```
<name>.<agent1>.<agent2>.md     → only for listed agents
<name>.md                       → for ALL agents
```

### Examples

```
context/
├── codestyle.coder.reviewer.md        → coder + reviewer only
├── review-checklist.reviewer.md       → reviewer only
├── test-conventions.tester.md         → tester only
├── api-patterns.coder.planner.md      → coder + planner
├── project-overview.md                → all agents (no agent suffix)
└── README.md                          → ignored (this file)
```

## Agent Names

Use these names in filenames:
- `planner`
- `coder`
- `tester`
- `tester_e2e`
- `tester_qa`
- `reviewer`
- `report`
- `git`

## How It Works

Before each agent call, the pipeline scans this folder and appends matching files to the agent's prompt as `<context>` sections. Files are sorted alphabetically.
