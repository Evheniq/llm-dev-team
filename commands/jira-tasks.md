Parse Jira tasks from the user input and create task folders with `task.md` files in `llm-dev-team/tasks/`.

## Input format

The argument `$ARGUMENTS` contains one or more Jira tasks. Each task has:
- **ID** — Jira task identifier (e.g. BT-1234)
- **Short name** — brief title
- **Description** — what needs to be done

Tasks may have hierarchy: a parent task with child (sub) tasks. The user may use indentation, numbering, or explicit "parent/child" markers to indicate hierarchy.

## What to do

1. Parse all tasks from `$ARGUMENTS`.
2. For each **parent** (top-level) task, create a folder: `llm-dev-team/tasks/<TASK_ID>-<short-name-kebab-case>/`
3. Inside it, create `task.md` using the template below.
4. For each **child** task of that parent, create a subfolder: `llm-dev-team/tasks/<PARENT_ID>-<parent-short-name>/<CHILD_ID>-<child-short-name>/`
5. Inside the subfolder, create `task.md` for the child task.
6. If a task has no parent/children (standalone), treat it as a top-level task.

## task.md template

```markdown
# <TASK_ID>: <Title>

## Description
<Description from the user input. Keep it as-is or lightly format into markdown.>

## Requirements
<Extract specific requirements from the description as bullet points. If the description is too vague, write "- See description above" as a placeholder.>

## Acceptance Criteria
<Extract acceptance criteria from the description as a checklist. If not explicitly stated, derive reasonable criteria from the description.>

## Implementation Notes
<Any specific guidance, constraints, or patterns mentioned in the description. If none, omit this section.>

## Pipeline Command
\`\`\`bash
./run.sh task tasks/<folder-name>
\`\`\`
```

## Rules
- Folder names: `<TASK_ID>-<short-name-in-kebab-case>` (lowercase, hyphens, no special chars)
- Do NOT overwrite existing task folders — if a folder already exists, warn the user and skip it
- Short name in folder: max 5-6 words, kebab-case
- Keep the original task description text — do not invent requirements that aren't implied
- After creating all tasks, print a summary tree of what was created
