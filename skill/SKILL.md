---
name: ralph
description: "Ralph Wiggum sequential story executor. Runs stories autonomously with fresh context per story, git commits as checkpoints, and Amelia review on blocks."
argument-hint: "[epic-number] [--retry-blocked] [--start-from N.M] [--review-every N] [--dry-run]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Ralph Wiggum Story Executor

You are the setup and launch agent for the Ralph Wiggum sequential story executor.
Your job is to validate prerequisites, initialize state, and launch the bash loop.
You do NOT execute stories yourself — `ralph.sh` handles that via fresh `claude -p` processes.

**Story files are read-only.** Ralph writes execution state to `_ralph/story-N.M-record.md`.

## Arguments

- `$ARGUMENTS[0]` — Epic number (required unless `--retry-blocked`)
- `--retry-blocked` — Re-attempt previously blocked stories
- `--start-from N.M` — Start from a specific story (e.g., `1.3`)
- `--review-every N` — Call Amelia review every N stories (default: only on block)
- `--dry-run` — Show what would execute without running
- `--help` — Show ralph.sh usage

## Setup Procedure

### Step 1: Validate Prerequisites

Read `ralph.config` (in this skill directory) for configured paths. Check these exist:

1. **Story files**: Glob for `{STORIES_DIR}/{epic}-*-*.md`
   - If none found: "No story files found for Epic {N}."
2. **Ralph scripts**: `.claude/skills/ralph/scripts/ralph.sh`
3. **Project context**: Check configured path
   - If missing, warn but continue

### Step 2: List Stories and Initialize PROGRESS.md

1. Glob story files and list all found
2. Extract story key and title from each file (first line: `# Story N.M: Title`)
3. Display the story list to the user for confirmation

If `_ralph/PROGRESS.md` doesn't exist (fresh run), create it:

```markdown
# Ralph Wiggum Progress

## Run Info
- Epic: {epic_number}
- Started: {timestamp}
- Branch: ralph/epic-{epic_number}
- Stories: {count}

## Stories
| Key | Title | Status | Attempts | Notes |
|-----|-------|--------|----------|-------|
| 1.1 | First Story Title | pending | 0 | |
| 1.2 | Second Story Title | pending | 0 | |
...

## Relay Notes
_Notes from completed stories for the next iteration to read._
```

If `_ralph/PROGRESS.md` already exists (resuming), read it and report current state.

Create `_ralph/` directory if it doesn't exist.

### Step 3: Create Feature Branch

```bash
CURRENT=$(git branch --show-current)
TARGET="ralph/epic-$EPIC_NUM"

if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  git checkout -b "$TARGET"
elif [ "$CURRENT" = "$TARGET" ]; then
  echo "Already on $TARGET, resuming."
else
  echo "WARNING: Currently on $CURRENT, expected main or $TARGET"
fi
```

### Step 4: Launch ralph.sh

```bash
bash .claude/skills/ralph/scripts/ralph.sh --epic "$EPIC_NUM"
```

Pass through any user flags (`--retry-blocked`, `--start-from`, `--review-every`, `--dry-run`).

Report to the user:
- How many stories will be processed
- Which branch they're on
- That they can monitor `_ralph/PROGRESS.md` and `_ralph/BLOCKERS.md`

## Notes

- **Story files are READ-ONLY.** Execution state goes to `_ralph/story-N.M-record.md`.
- **Sprint status is kept in sync** (if configured).
- The `_ralph/` directory is auto-added to `.gitignore`.
- `ralph.sh` runs as a long-running foreground process.
- If interrupted, run `git checkout .` to clean up. Do NOT run `git clean -fd`.
