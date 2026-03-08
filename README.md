# Universal Task Pipeline

Multi-agent automation pipeline for implementing software tasks end-to-end.
Orchestrates Claude AI agents through a structured workflow: plan → code → test → review → report.

## Architecture

```
                     ┌──────────────────────────────────────┐
                     │  combined feedback (from all validators) │
                     └──────────────────┬───────────────────┘
                                        │
                                        ▼
┌───────────┐     ┌──────────┐     ┌─────────────────────────────┐
│  PLANNER  ├────►│  CODER   ├────►│     PARALLEL VALIDATION     │
│ (analyze  │     │ (write + │     │                             │
│  + plan)  │     │  build)  │     │  ┌────────┐  ┌──────────┐  │
└───────────┘     └──────────┘     │  │ TESTER │  │   E2E    │  │
                                   │  │ (unit) │  │  (curl)  │  │
                                   │  └────┬───┘  └────┬─────┘  │
                                   │       │           │         │
                                   │  ┌────┴───────────┴─────┐  │
                                   │  │      REVIEWER        │  │
                                   │  │   (code quality)     │  │
                                   │  └──────────┬───────────┘  │
                                   └─────────────┼──────────────┘
                                                 │
                                    ALL PASS? ───┤
                                       │YES      │NO
                                       ▼         ▼
                                  ┌──────────┐  combined
                                  │ QA + RPT │  feedback ↑
                                  └──────────┘
```

## Quick Start

```bash
# 1. Copy and customize config
cp config.env.example config.env
vi config.env   # Set LANGUAGE, BUILD_CMD, TEST_CMD, etc.

# 2. Create a task
mkdir -p tasks/MY-123-feature
cat > tasks/MY-123-feature/task.md << 'EOF'
# MY-123: Feature Description
## Requirements
- ...
## Acceptance Criteria
- [ ] ...
EOF

# 3. Run the pipeline
./run.sh task tasks/MY-123-feature
```

## Pipeline Modes

| Mode | Command | Description |
|------|---------|-------------|
| `task` | `./run.sh task <dir>` | Full pipeline with task context collection |
| `feature` | `./run.sh feature "desc"` | Quick plan→code→test→review from description |
| `review` | `./run.sh review "scope"` | Review-only for existing code |
| `e2e` | `./run.sh e2e <dir>` | E2E tests only (re-verification) |
| `followup` | `./run.sh followup <dir> "instruction"` | Fix/adjust a completed task using its full context |

## Options

```
--max-iter N          Max iterations (replan strategy, default: 5)
--max-fix-iter N      Max fix cycles (direct strategy, default: 3)
--feedback <file>     Resume from a previous feedback file
--dry-run             Show flow without calling Claude
--model <name>        Override MODEL
--review-model <name> Override REVIEW_MODEL
--strategy <s>        direct or replan
--e2e / --no-e2e      Toggle E2E testing
--no-qa               Skip QA generation
--no-report           Skip report generation
--no-retro            Skip retrospective analysis
--git / --no-git      Toggle git operations
```

## Feedback Strategies

### `replan` (default)
Any failure (test, E2E, review) → feedback → **planner re-analyzes** → full cycle.
Best for complex tasks where failures may indicate a wrong approach.

### `direct`
Plan once → code → test → review → fix cycle (coder fixes directly from review).
Best for straightforward tasks where the plan is likely correct.

## Followup Mode

Reuse the full context of a previously completed task to make adjustments or fixes:

```bash
# Fix a specific issue from reviewer notes
./run.sh followup tasks/HAP-625-image-search "MIME validation should use http.DetectContentType instead of trusting Content-Type header"

# Add something that was missed
./run.sh followup tasks/CD-24368 "Add support for description_orderid flag in the moneyout request"

# Ask a question about the implementation
./run.sh followup tasks/HAP-625-image-search "Why was SHA256 chosen over MD5 for cache keys?"
```

What happens under the hood:
1. Loads the latest run artifacts (task context, plan, code changes, review)
2. Combines them into a single enriched context
3. Appends your instruction as the new focus
4. Runs through the standard plan → code → test → review cycle

The planner sees everything that was already done and focuses only on the new instruction.

## Agents

| Agent | Model | Tools | Purpose |
|-------|-------|-------|---------|
| planner | MODEL | Read, Grep, Glob, Bash | Analyze codebase, create implementation plan |
| coder | MODEL | Read, Write, Edit, Bash, Grep, Glob | Implement plan with self-verification |
| tester | MODEL | Read, Write, Edit, Bash, Grep, Glob | Run static analysis + unit tests |
| tester_e2e | MODEL | Read, Bash, Grep, Glob | E2E HTTP testing against running server |
| tester_qa | REPORT_MODEL | Read, Grep, Glob | Generate QA test documentation |
| reviewer | REVIEW_MODEL | Read, Grep, Glob, Bash | Code review with structured checklist |
| report | REPORT_MODEL | Read, Grep, Glob | Generate implementation report |
| retrospective | REVIEW_MODEL | Read, Grep, Glob | Analyze multi-iteration runs, propose prompt improvements |
| git | MODEL | Read, Bash, Grep, Glob | Branch creation, commit, push |

## Retrospective (Self-Improvement)

When a pipeline run requires multiple iterations (test failures, reviewer change requests), the retrospective agent automatically analyzes what went wrong and proposes improvements.

**How it works:**
1. After approval, if `CURRENT_ITERATION > 1`, the retrospective agent reads all run artifacts
2. It diagnoses root causes and categorizes issues as `prompt_improvement`, `task_context_improvement`, or `one_off`
3. For systemic issues, it proposes exact text changes to agent prompts or context files
4. You review each proposed change interactively: `y` (approve) / `n` (decline) / `s` (skip all)
5. Approved changes are saved to `pending_changes.md` in the run directory (not auto-applied)
6. Lessons learned are appended to `data/lessons_learned.md` — persistent across runs

**Configuration:**
- `RETRO_ENABLED=true` in config.env (default: enabled)
- `--no-retro` flag to skip for a specific run
- Non-fatal: if retrospective fails, the pipeline continues normally

## Customization

### For a new project

1. **config.env**: Set `LANGUAGE`, `BUILD_CMD`, `TEST_CMD`, `LINT_CMD`
2. **agents/*.md**: Customize prompts for your project's patterns
3. **context/**: Add project-specific files injected into agent prompts (see below)
4. **hooks/**: Add project-specific hooks (deploy, notify, migrate)
5. **data/**: Add domain-specific data files for agents
6. **tools/**: Add custom CLI tools agents can use

### Context Files

Place `.md` files in `context/` to inject project knowledge into agent prompts.
Agent targets are specified in the filename:

```
context/
├── codestyle.coder.reviewer.md      → coder + reviewer only
├── review-checklist.reviewer.md     → reviewer only
├── test-conventions.tester.md       → tester only
├── api-patterns.coder.planner.md    → coder + planner
└── project-overview.md              → ALL agents (no suffix)
```

Agent names: `planner`, `coder`, `tester`, `tester_e2e`, `tester_qa`, `reviewer`, `report`, `retrospective`, `git`

### Hooks

Copy `.example` files and remove the suffix to activate:

| Hook | When | Use Case |
|------|------|----------|
| `pre_pipeline.sh` | Before start | Start Docker, check deps |
| `pre_code.sh` | Before coder | Install deps, seed data |
| `post_approve.sh` | After approval | Notify, deploy, generate configs |
| `post_pipeline.sh` | At exit | Cleanup, stop services |

## Directory Structure

```
pipeline_template/
├── run.sh                 # Main orchestrator
├── config.env.example     # Configuration template
├── agents/                # Agent prompt templates
│   ├── planner.md
│   ├── coder.md
│   ├── tester.md
│   ├── tester_e2e.md
│   ├── tester_qa.md
│   ├── reviewer.md
│   ├── report.md
│   └── git.md
├── lib/                   # Shell libraries
│   ├── config.sh          # Config loading, arg parsing
│   ├── logging.sh         # Colored logging
│   ├── artifacts.sh       # Artifact sequencing
│   ├── metrics.sh         # Timing, JSON metrics
│   ├── agent.sh           # Claude agent runner + retry
│   ├── feedback.sh        # Verdict parsing, feedback loop
│   ├── git_ops.sh         # Git operations
│   └── server.sh          # Server lifecycle for E2E
├── context/               # Project-specific files for agents (by naming convention)
├── hooks/                 # Extensibility hooks
├── data/                  # Domain data files
├── tools/                 # Custom CLI tools
├── tasks/                 # Task definitions (runs stored inside each task)
└── runs/                  # Runs for taskless modes (feature, review)
```

## Artifacts

Each run generates numbered files in `tasks/<task>/runs/<timestamp>/`:

```
01_task_context.md      — Collected task + subtask context
02_planner_output.md    — Implementation plan
03_coder_output.md      — Coding results + verification
04_test_report.md       — Static analysis + unit tests
05_tester_e2e.md        — E2E test results (if enabled)
06_reviewer_output.md   — Code review verdict
07_tester_qa_cases.md   — QA test cases (if enabled)
08_report.md            — Final report (if enabled)
09_retrospective.md     — Retrospective analysis (if multi-iteration)
pending_changes.md      — User-approved prompt changes (if any)
metrics.json            — Timing + config snapshot
pipeline.log            — Full execution log
```
