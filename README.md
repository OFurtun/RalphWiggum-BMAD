# RalphWiggum-BMAD

A sequential story executor for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using the [Ralph Wiggum method](https://www.geoffreyhuntley.com/ralph-wiggum).

Each story gets a **fresh `claude -p` process** with zero context accumulation. Progress persists in the filesystem and git history — forced amnesia is a feature, not a bug.

Works with [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD) projects out of the box. Also works with any project that has markdown story files.

## Quick Start

```bash
# Clone the installer
git clone https://github.com/OFurtun/RalphWiggum-BMAD.git /tmp/ralph-installer

# Install into your project
/tmp/ralph-installer/install.sh /path/to/your/project

# Execute stories (from your project directory)
cd /path/to/your/project
/ralph 1                    # via Claude Code skill
# or
bash .claude/skills/ralph/scripts/ralph.sh --epic 1   # direct
```

## What It Does

For each story in an epic:

1. **Ralph** (a fresh `claude -p`) reads the story spec + progress baton, implements it, commits on test pass
2. If Ralph blocks, **Amelia** (another fresh `claude -p`) reviews with full architecture access and provides guidance
3. On retry, Ralph gets the attempt count + blocker reason + Amelia's guidance
4. Regression tests run between stories
5. Loop continues to the next story

```
ralph.sh (bash loop)           ← Zero intelligence. Parses signals, calls processes.
    │
    ├── claude -p (Ralph)      ← Fresh process per story. Reads spec. Commits code.
    │
    └── claude -p (Amelia)     ← Fresh process on block. Reads docs. Provides guidance.
```

## Architecture

```
                              /ralph --epic N
                                    │
                    ┌───────────────────────────────┐
                    │          SKILL.md              │
                    │                               │
                    │  Validate prerequisites        │
                    │  Initialize PROGRESS.md        │
                    │  Create branch ralph/epic-N    │
                    └───────────────┬───────────────┘
                                    │
     ┌──────────────────────────────▼──────────────────────────────┐
     │                       ralph.sh                              │
     │                  "Zero intelligence bash loop"              │
     │                                                             │
     │  ┌────────────────────────────────────────────────────────┐ │
     │  │  OUTER LOOP ─ for each story (sequential)             │ │
     │  │                                                        │ │
     │  │  Read PROGRESS.md → skip done/blocked → set in-progress│ │
     │  │                                                        │ │
     │  │  ┌──────────────────────────────────────────────────┐  │ │
     │  │  │  INNER LOOP ─ continuations (max 5 per story)    │  │ │
     │  │  │                                                  │  │ │
     │  │  │  ┌──────────────────────────────────┐            │  │ │
     │  │  │  │    Fresh claude -p  (Ralph)       │            │  │ │
     │  │  │  │    Zero context accumulation      │            │  │ │
     │  │  │  │                                   │            │  │ │
     │  │  │  │  Reads:                           │            │  │ │
     │  │  │  │   • Story file (read-only spec)   │            │  │ │
     │  │  │  │   • PROGRESS.md (relay baton)     │            │  │ │
     │  │  │  │   • project-context.md            │            │  │ │
     │  │  │  │   • Retry context (if attempt >1) │            │  │ │
     │  │  │  │                                   │            │  │ │
     │  │  │  │  Does:                            │            │  │ │
     │  │  │  │   • Implements tasks in order     │            │  │ │
     │  │  │  │   • Commits after each task       │            │  │ │
     │  │  │  │   • Runs check/test/lint          │            │  │ │
     │  │  │  └──────────────┬────────────────────┘            │  │ │
     │  │  │                 │                                 │  │ │
     │  │  │        ┌────────┴────────┬──────────────┐         │  │ │
     │  │  │        ▼                 ▼              ▼         │  │ │
     │  │  │     DONE             BLOCKED        MAX-TURNS     │  │ │
     │  │  │       ✓                ✗           (no signal)    │  │ │
     │  │  │       │                │              │           │  │ │
     │  │  │       │                │         commits made?    │  │ │
     │  │  │       │                │          ╱        ╲      │  │ │
     │  │  │       │                │        YES         NO    │  │ │
     │  │  │       │                │         │           │    │  │ │
     │  │  │       │                │     CONTINUE     BLOCK   │  │ │
     │  │  │       │                │     (new fresh   (same   │  │ │
     │  │  │       │                │      process,    as      │  │ │
     │  │  │       │                │      git work    blocked)│  │ │
     │  │  │       │                │      preserved)          │  │ │
     │  │  └───────┼────────────────┼──────────────────────────┘  │ │
     │  │          │                │                              │ │
     │  │          │       ┌────────▼────────────────┐             │ │
     │  │          │       │  Fresh claude -p (Amelia)│             │ │
     │  │          │       │  Senior code reviewer   │             │ │
     │  │          │       │                         │             │ │
     │  │          │       │  Reads everything:      │             │ │
     │  │          │       │   • PROGRESS.md         │             │ │
     │  │          │       │   • BLOCKERS.md         │             │ │
     │  │          │       │   • git log             │             │ │
     │  │          │       │   • Architecture docs   │             │ │
     │  │          │       │                         │             │ │
     │  │          │       │  Verdict:               │             │ │
     │  │          │       │  ┌────────┬────────┐    │             │ │
     │  │          │       │  │ RETRY  │  HALT  │    │             │ │
     │  │          │       │  │ +guide │  stop  │    │             │ │
     │  │          │       │  └───┬────┴───┬────┘    │             │ │
     │  │          │       └──────┼────────┼─────────┘             │ │
     │  │          │              │        │                       │ │
     │  │          │         inner loop    ▼                       │ │
     │  │          │         (w/ guidance) STOP ──► Human          │ │
     │  │          │                                               │ │
     │  │          ▼                                               │ │
     │  │     next story ─────────────────────────────────────►    │ │
     │  └─────────────────────────────────────────────────────────┘ │
     └─────────────────────────────────────────────────────────────┘

              ┌─────────── Shared State ───────────┐
              │                                     │
              │  PROGRESS.md       git history      │
              │  (relay baton)     (committed code)  │
              │  ┌────────────┐   ┌──────────────┐  │
              │  │ Story table │   │ feat: Task 1 │  │
              │  │ Relay notes │   │ feat: Task 2 │  │
              │  │ Attempts    │   │ test: Task 3 │  │
              │  └────────────┘   └──────────────┘  │
              │                                     │
              │  BLOCKERS.md       story-N.M-record │
              │  (failure log)     (execution log)   │
              │  ┌────────────┐   ┌──────────────┐  │
              │  │ Issue       │   │ Duration     │  │
              │  │ Attempts    │   │ Amelia notes │  │
              │  │ Needs       │   │ File list    │  │
              │  └────────────┘   └──────────────┘  │
              └─────────────────────────────────────┘
```

Each `claude -p` invocation is a **disposable worker** with zero memory. The only things that survive between runs are **PROGRESS.md** (the relay baton) and **git commits** (the actual work). Ralph follows the story spec mechanically; Amelia provides the brains when things go wrong.

## Installation

```bash
./install.sh [project-directory]
```

The interactive installer:
1. Asks which project to install into
2. Detects BMAD (sets defaults automatically) or uses generic defaults
3. Configures story paths, test commands, architecture docs
4. Copies everything into `{project}/.claude/skills/ralph/`
5. Generates a `ralph.config` with your settings

### What Gets Installed

```
your-project/
└── .claude/skills/ralph/
    ├── SKILL.md                    # Claude Code skill definition (/ralph)
    ├── ralph.config                # Your project-specific configuration
    └── scripts/
        ├── ralph.sh                # Bash loop orchestrator
        ├── ralph-prompt.md         # Ralph's system prompt
        └── amelia-review-prompt.md # Amelia's system prompt
```

### Configuration

| Setting | BMAD Default | Generic Default |
|---------|-------------|-----------------|
| Stories directory | `_bmad-output/implementation-artifacts` | `stories` |
| Project context | `_bmad-output/planning-artifacts/project-context.md` | `none` |
| Architecture docs | `_bmad-output/planning-artifacts/architecture/` | `none` |
| Sprint status | `_bmad-output/implementation-artifacts/sprint-status.yaml` | `none` |
| Runtime directory | `_ralph` | `_ralph` |
| Test command | `npm run test` | `npm run test` |
| Check command | `npm run check` | `npm run check` |
| Lint command | `npm run lint` | `npm run lint` |

Edit `ralph.config` anytime to reconfigure, or re-run `install.sh`.

## Usage

```bash
# Execute all stories in an epic
/ralph 1
ralph.sh --epic 1

# Resume from a specific story
ralph.sh --epic 1 --start-from 1.5

# Retry previously blocked stories
ralph.sh --epic 1 --retry-blocked

# Amelia reviews every 3 stories (not just on block)
ralph.sh --epic 1 --review-every 3

# Preview without executing
ralph.sh --epic 1 --dry-run

# More turns for complex stories
ralph.sh --epic 2 --max-turns 80

# Full help
ralph.sh --help
```

## Story File Format

Ralph works with any markdown story file named `{epic}-{story}-{slug}.md` that has:

- A title line: `# Story N.M: Title`
- **Tasks / Subtasks** section with checkboxes
- **Acceptance Criteria** section

BMAD dev-agent format stories work out of the box. See [examples/story-template.md](examples/story-template.md) for a minimal template.

## How It Works

### The Relay Baton

`_ralph/PROGRESS.md` carries state between iterations:

```markdown
## Stories
| Key | Title | Status | Attempts | Notes |
|-----|-------|--------|----------|-------|
| 1.1 | Project Scaffold | done | 1 | completed 2025-02-27 |
| 1.2 | Database Foundation | in-progress | 1 | |
| 1.3 | Auth & Sessions | pending | 0 | |

## Relay Notes
### Story 1.1
- Files created: src/lib/services/logger.ts
- Key patterns: pino logger with requestLogger() helper
```

### Story Files are Read-Only

Ralph never modifies story files. Execution notes go to `_ralph/story-N.M-record.md`. This prevents data loss when `git checkout .` reverts uncommitted changes on blocks.

### Completion Signals

Ralph outputs one of:
- `<promise>STORY-N.M-DONE</promise>` — story completed
- `<promise>STORY-N.M-BLOCKED:reason</promise>` — story blocked

### Amelia's Verdicts

```json
{
  "action": "retry",
  "story": "1.2",
  "reason": "Missing RLS pattern",
  "guidance": "The pattern is: ENABLE ROW LEVEL SECURITY ...",
  "relay_notes": "Story 1.2 needs explicit RLS on all tables"
}
```

Actions: `continue` | `retry` | `skip` | `halt`

### Retry Awareness

On retry, Ralph receives:
- Attempt number
- Previous block reason
- Amelia's guidance from the record file

### Safety

- `git checkout .` only (never `git clean -fd`)
- Explicit file staging (never `git add -A`)
- `_ralph/` auto-added to `.gitignore`
- Regression tests between stories

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude` command)
- `bash` 4+
- `git`
- `jq` (recommended — falls back to grep-based parsing)

## Credits

- **Ralph Wiggum Method**: [Geoffrey Huntley](https://www.geoffreyhuntley.com/ralph-wiggum) (February 2025)
- **Relay Baton Pattern**: [Anand Chowdhary](https://anandchowdhary.com/blog/ralph-wiggum)
- **BMAD Method**: [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD)

## License

MIT
