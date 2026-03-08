# Task Management

## Structure

Each task lives in its own folder under `tasks/`. Runs are stored inside the task:

```
tasks/
├── TASK-123-feature-name/
│   ├── task.md              # Main task description (required)
│   ├── docs/                # Supporting documentation (optional)
│   │   ├── api-spec.md
│   │   └── design.md
│   ├── TASK-124-subtask/    # Subtask folder (optional)
│   │   └── task.md
│   └── runs/                # Pipeline execution history
│       ├── 2026-03-02_10-57-32/
│       │   ├── 01_task_context.md
│       │   ├── 02_planner_output.md
│       │   ├── ...
│       │   ├── SUMMARY.md
│       │   └── metrics.json
│       └── 2026-03-05_14-20-00/
│           └── ...
```

## Creating a Task

1. Create a folder: `tasks/<TASK_ID>-<short-description>/`
2. Create `task.md` using the template below
3. Add supporting docs to `docs/` if needed
4. For complex tasks, split into subtasks (subfolders with `task.md`)

## task.md Template

```markdown
# <Task ID>: <Title>

## Description
What needs to be implemented and why.

## Requirements
- Requirement 1
- Requirement 2
- Requirement 3

## API / Interface
(endpoints, function signatures, data structures)

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Implementation Notes
(specific guidance, constraints, patterns to follow)

## Pipeline Command
\`\`\`bash
./run.sh task tasks/<folder-name>
\`\`\`
```

## Subtasks

For complex features, split into subtasks:
- Each subtask gets its own folder with a `task.md`
- The pipeline automatically collects all subtask files
- Subtasks are included in the context for planning

## Run Artifacts

After a pipeline run, artifacts are saved to `tasks/<task>/runs/<timestamp>/`:
- `01_task_context.md` — collected task + subtask context
- `02_planner_output.md` — implementation plan
- `03_coder_output.md` — coding results
- `04_test_report.md` — test results
- `05_reviewer_output.md` — code review
- `06_tester_qa_cases.md` — QA test cases (if enabled)
- `07_report.md` — final report (if enabled)
- `metrics.json` — timing and config snapshot
- `pipeline.log` — full execution log
