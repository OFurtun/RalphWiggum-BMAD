#!/usr/bin/env bash
set -euo pipefail

# Allow nested claude -p processes when launched from within a Claude Code session
unset CLAUDECODE 2>/dev/null || true

# Ralph Wiggum Sequential Story Executor
# Each story gets a fresh claude -p process. Zero context accumulation.
# Progress persists in PROGRESS.md (the relay baton) and git history.

# ─── Find config (next to this script's parent) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${RALPH_CONFIG:-$SKILL_DIR/ralph.config}"

# ─── Defaults ───
EPIC=""
STORIES_DIR="_bmad-output/implementation-artifacts"
PROJECT_CONTEXT="_bmad-output/planning-artifacts/project-context.md"
SPRINT_STATUS="_bmad-output/implementation-artifacts/sprint-status.yaml"
RUNTIME_DIR="_ralph"
RALPH_PROMPT="$SCRIPT_DIR/ralph-prompt.md"
AMELIA_PROMPT="$SCRIPT_DIR/amelia-review-prompt.md"
TEST_CMD="npm run test"
CHECK_CMD="npm run check"
LINT_CMD="npm run lint"
MAX_TURNS=200
MAX_CONTINUATIONS=5  # max fresh instances for same story on max-turns (if progress is made)
AMELIA_MAX_TURNS=20
REVIEW_EVERY=0  # 0 = only on block
START_FROM=""
RETRY_BLOCKED=false
DRY_RUN=false

# ─── Load config if it exists ───
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Derived paths (after config load)
PROGRESS_FILE="${PROGRESS_FILE:-$RUNTIME_DIR/PROGRESS.md}"
BLOCKERS_FILE="${BLOCKERS_FILE:-$RUNTIME_DIR/BLOCKERS.md}"

# ─── Help ───
show_help() {
  cat <<'HELP'
Ralph Wiggum Sequential Story Executor
=======================================

Each story gets a fresh claude -p process with zero context accumulation.
Progress persists in PROGRESS.md (the relay baton) and git history.

USAGE:
  ralph.sh --epic <N> [OPTIONS]

REQUIRED:
  --epic <N>              Epic number to execute (e.g., 1)

OPTIONS:
  --stories-dir <path>    Story files directory
  --progress <path>       Progress file path
  --project-context <p>   Project context file
  --ralph-prompt <path>   Ralph system prompt
  --amelia-prompt <path>  Amelia review prompt
  --max-turns <N>         Max turns per story (default: 200)
  --review-every <N>      Call Amelia review every N stories (default: 0 = only on block)
  --start-from <N.M>      Start from specific story (e.g., 1.3)
  --retry-blocked         Re-attempt previously blocked stories
  --dry-run               Show what would execute without running
  --config <path>         Path to ralph.config (default: auto-detected)

EXAMPLES:
  ralph.sh --epic 1                         Execute all Epic 1 stories
  ralph.sh --epic 1 --start-from 1.5        Resume from Story 1.5
  ralph.sh --epic 1 --retry-blocked         Retry blocked stories
  ralph.sh --epic 1 --review-every 3        Amelia reviews every 3 stories
  ralph.sh --epic 1 --dry-run               Preview without executing
  ralph.sh --epic 2 --max-turns 80          More turns for complex stories

STORY LIFECYCLE:
  pending → in-progress → done | blocked | skipped

COMPLETION SIGNALS:
  <promise>STORY-N.M-DONE</promise>           Story completed
  <promise>STORY-N.M-BLOCKED:reason</promise>  Story blocked after 3 attempts

FILES:
  {runtime}/PROGRESS.md                       Relay baton between iterations
  {runtime}/BLOCKERS.md                       Failure log
  {runtime}/story-N.M-record.md               Execution records (per story)

ARCHITECTURE:
  Ralph (claude -p)   → Fresh process per story, executes spec, commits on test pass
  Amelia (claude -p)  → Fresh process on block/review, reads architecture, provides guidance
  ralph.sh            → Bash loop orchestrator, zero intelligence, parses completion signals
HELP
  exit 0
}

# ─── Parse arguments (override config) ───
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) show_help ;;
    --epic) EPIC="$2"; shift 2 ;;
    --stories-dir) STORIES_DIR="$2"; shift 2 ;;
    --progress) PROGRESS_FILE="$2"; shift 2 ;;
    --project-context) PROJECT_CONTEXT="$2"; shift 2 ;;
    --ralph-prompt) RALPH_PROMPT="$2"; shift 2 ;;
    --amelia-prompt) AMELIA_PROMPT="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    --review-every) REVIEW_EVERY="$2"; shift 2 ;;
    --start-from) START_FROM="$2"; shift 2 ;;
    --retry-blocked) RETRY_BLOCKED=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --config) CONFIG_FILE="$2"; source "$CONFIG_FILE"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
  esac
done

if [ -z "$EPIC" ]; then
  echo "ERROR: --epic is required"
  echo "Use --help for usage."
  exit 1
fi

# ─── Validate prerequisites ───
if [ ! -f "$RALPH_PROMPT" ]; then
  echo "ERROR: Ralph prompt not found: $RALPH_PROMPT"
  exit 1
fi

if [ "$PROJECT_CONTEXT" != "none" ] && [ ! -f "$PROJECT_CONTEXT" ]; then
  echo "WARNING: Project context not found: $PROJECT_CONTEXT"
  echo "  Ralph will operate without coding standards."
  echo ""
fi

if [ ! -f "$AMELIA_PROMPT" ]; then
  echo "WARNING: Amelia prompt not found: $AMELIA_PROMPT"
  echo "  Block reviews will be skipped."
  echo ""
fi

# ─── Ensure runtime dir is gitignored ───
mkdir -p "$RUNTIME_DIR"
if [ ! -f ".gitignore" ] || ! grep -q "^${RUNTIME_DIR}/" ".gitignore" 2>/dev/null; then
  echo "${RUNTIME_DIR}/" >> ".gitignore"
  echo "Added ${RUNTIME_DIR}/ to .gitignore"
fi

# ─── Build static context (same for every iteration) ───
STATIC_CONTEXT="$(cat "$RALPH_PROMPT")"
if [ "$PROJECT_CONTEXT" != "none" ] && [ -f "$PROJECT_CONTEXT" ]; then
  STATIC_CONTEXT="$STATIC_CONTEXT

---

$(cat "$PROJECT_CONTEXT")"
fi

# ─── Helpers ───
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

read_progress_field() {
  local key="$1"
  local col="$2"
  awk -F'|' -v key="$key" -v col="$col" '
    $0 ~ "^\\| "key" " {
      gsub(/^ +| +$/, "", $(col+1))
      print $(col+1)
    }
  ' "$PROGRESS_FILE"
}

get_story_status() { read_progress_field "$1" 3; }
get_story_attempts() { read_progress_field "$1" 4; }
get_story_notes() { read_progress_field "$1" 5; }

update_progress_row() {
  local key="$1" new_status="$2" new_attempts="$3" new_notes="$4"
  local tmpfile
  tmpfile=$(mktemp)
  awk -F'|' -v key="$key" -v status="$new_status" -v attempts="$new_attempts" -v notes="$new_notes" '
    BEGIN { OFS="|" }
    $0 ~ "^\\| "key" " {
      title = $3; gsub(/^ +| +$/, "", title)
      print "| " key " | " title " | " status " | " attempts " | " notes " |"
      next
    }
    { print }
  ' "$PROGRESS_FILE" > "$tmpfile" && mv "$tmpfile" "$PROGRESS_FILE"
}

update_story_status() {
  local key="$1" new_status="$2" new_notes="$3"
  local current_attempts
  current_attempts=$(get_story_attempts "$key")
  update_progress_row "$key" "$new_status" "$current_attempts" "$new_notes"
}

increment_attempts() {
  local key="$1" current status notes
  current=$(get_story_attempts "$key")
  status=$(get_story_status "$key")
  notes=$(get_story_notes "$key")
  update_progress_row "$key" "$status" "$((current + 1))" "$notes"
}

append_relay_notes() {
  echo "" >> "$PROGRESS_FILE"
  echo "$1" >> "$PROGRESS_FILE"
}

update_sprint_status() {
  local story_key="$1" new_status="$2"
  if [ "$SPRINT_STATUS" = "none" ] || [ ! -f "$SPRINT_STATUS" ]; then return; fi
  local epic_num story_num sprint_stat
  epic_num=$(echo "$story_key" | cut -d'.' -f1)
  story_num=$(echo "$story_key" | cut -d'.' -f2)
  local pattern="  ${epic_num}-${story_num}-"
  case "$new_status" in
    in-progress) sprint_stat="in-progress" ;;
    done)        sprint_stat="done" ;;
    blocked)     sprint_stat="in-progress" ;;
    skipped)     sprint_stat="ready-for-dev" ;;
    *)           return ;;
  esac
  local tmpfile
  tmpfile=$(mktemp)
  awk -v pat="$pattern" -v stat="$sprint_stat" '
    index($0, pat) == 1 { match($0, /: /); print substr($0, 1, RSTART + 1) stat; next }
    { print }
  ' "$SPRINT_STATUS" > "$tmpfile" && mv "$tmpfile" "$SPRINT_STATUS"
}

parse_json_field() {
  local output="$1" field="$2" value=""
  if command -v jq &>/dev/null; then
    value=$(echo "$output" | sed -n '/^{/,/^}/p' | jq -r ".$field // empty" 2>/dev/null)
    [ -n "$value" ] && { echo "$value"; return; }
    value=$(echo "$output" | sed -n '/```json/,/```/p' | sed '1d;$d' | jq -r ".$field // empty" 2>/dev/null)
    [ -n "$value" ] && { echo "$value"; return; }
  fi
  echo "$output" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"$field\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
}

parse_json_array_field() {
  local output="$1" field="$2"
  if command -v jq &>/dev/null; then
    local arr=""
    arr=$(echo "$output" | sed -n '/^{/,/^}/p' | jq -r ".$field[]? // empty" 2>/dev/null)
    [ -z "$arr" ] && arr=$(echo "$output" | sed -n '/```json/,/```/p' | sed '1d;$d' | jq -r ".$field[]? // empty" 2>/dev/null)
    echo "$arr"; return
  fi
  echo "$output" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | head -1
}

# ─── Collect stories ───
mapfile -t STORY_FILES < <(ls "$STORIES_DIR"/"$EPIC"-*-*.md 2>/dev/null | sort -V)

if [ ${#STORY_FILES[@]} -eq 0 ]; then
  echo "ERROR: No story files found in $STORIES_DIR for epic $EPIC"
  echo "  Expected files like: $STORIES_DIR/$EPIC-1-*.md"
  exit 1
fi

echo "═══════════════════════════════════════════════════"
echo "  Ralph Wiggum Executor — Epic $EPIC"
echo "  Stories: ${#STORY_FILES[@]}"
echo "  Branch: $(git branch --show-current)"
echo "  Max turns/story: $MAX_TURNS"
[ "$REVIEW_EVERY" -gt 0 ] && echo "  Amelia review: every $REVIEW_EVERY stories" || echo "  Amelia review: on block only"
echo "  Config: $CONFIG_FILE"
echo "  Started: $(timestamp)"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── Initialize blockers file ───
if [ ! -f "$BLOCKERS_FILE" ]; then
  { echo "# Ralph Wiggum Blockers"; echo ""; echo "_Stories that Ralph could not complete._"; echo ""; } > "$BLOCKERS_FILE"
fi

# ─── Main loop ───
COMPLETED=0 BLOCKED=0 SKIPPED=0 STORIES_SINCE_REVIEW=0

for STORY_FILE in "${STORY_FILES[@]}"; do
  BASENAME=$(basename "$STORY_FILE" .md)
  STORY_EPIC=$(echo "$BASENAME" | cut -d'-' -f1)
  STORY_NUM=$(echo "$BASENAME" | cut -d'-' -f2)
  STORY_KEY="${STORY_EPIC}.${STORY_NUM}"

  # Handle --start-from
  if [ -n "$START_FROM" ]; then
    [ "$STORY_KEY" != "$START_FROM" ] && continue || START_FROM=""
  fi

  STATUS=$(get_story_status "$STORY_KEY")

  # Skip logic
  if [ "$STATUS" = "done" ]; then echo "  ⏭  Story $STORY_KEY — already done"; continue; fi
  if [ "$STATUS" = "blocked" ] && [ "$RETRY_BLOCKED" = false ]; then echo "  ⏭  Story $STORY_KEY — blocked (use --retry-blocked)"; SKIPPED=$((SKIPPED + 1)); continue; fi
  if [ "$STATUS" = "skipped" ]; then echo "  ⏭  Story $STORY_KEY — skipped by review"; SKIPPED=$((SKIPPED + 1)); continue; fi

  CURRENT_ATTEMPTS=$(get_story_attempts "$STORY_KEY")

  echo "───────────────────────────────────────────────────"
  echo "  📋 Story $STORY_KEY — starting (attempt $((CURRENT_ATTEMPTS + 1)))"
  echo "  $(timestamp)"
  echo "───────────────────────────────────────────────────"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would execute: claude -p with $(wc -l < "$STORY_FILE") line story"
    echo "  [DRY RUN] Story file: $STORY_FILE"
    continue
  fi

  # ─── Regression test before new story ───
  if [ "$CURRENT_ATTEMPTS" -eq 0 ] && [ "$COMPLETED" -gt 0 ]; then
    echo "  🧪 Running regression tests..."
    if ! $TEST_CMD --if-present 2>/dev/null; then
      echo "  ⚠️  Regression tests failed before Story $STORY_KEY!"
      update_story_status "$STORY_KEY" "blocked" "regression test failure before start"
      update_sprint_status "$STORY_KEY" "blocked"
      BLOCKED=$((BLOCKED + 1))

      if [ -f "$AMELIA_PROMPT" ]; then
        echo "  🔍 Calling Amelia to evaluate regression..."
        AMELIA_OUTPUT=$(env -u CLAUDECODE claude -p "## Regression Test Failure
A regression test failed BEFORE starting Story $STORY_KEY.
## Progress
$(cat "$PROGRESS_FILE")
## Recent Git History
$(git log --oneline -20)
## Test Output
$($TEST_CMD --if-present 2>&1 | tail -50)" \
          --append-system-prompt "$(cat "$AMELIA_PROMPT")" \
          --max-turns "$AMELIA_MAX_TURNS" \
          --allowedTools "Read,Grep,Glob,Bash" \
          --output-format text 2>&1) || true

        [ "$(parse_json_field "$AMELIA_OUTPUT" "action")" = "halt" ] && { echo "  🛑 Amelia: HALT"; break; }
      fi
      continue
    fi
    echo "  ✅ Regression tests pass"
  fi

  # Update status
  update_story_status "$STORY_KEY" "in-progress" ""
  update_sprint_status "$STORY_KEY" "in-progress"
  increment_attempts "$STORY_KEY"

  # ─── Inner loop: execute with continuations on max-turns ───
  STORY_RESULT=""  # "done", "blocked", or "halt" — controls outer loop
  CONTINUATIONS=0

  while true; do
    # Build retry/continuation context
    RETRY_CONTEXT=""
    CURRENT_ATTEMPTS=$(get_story_attempts "$STORY_KEY")
    if [ "$CONTINUATIONS" -gt 0 ]; then
      RETRY_CONTEXT="
---
## CONTINUATION
**This is continuation #$CONTINUATIONS** (session $((CONTINUATIONS + 1)) of max $MAX_CONTINUATIONS).
The previous session hit the turn limit. Your committed work is preserved in git.
**Check git log and the codebase to see what's already done, then continue from where the previous session left off.**
Do NOT redo work that's already committed."
    elif [ "$CURRENT_ATTEMPTS" -gt 1 ]; then
      RETRY_CONTEXT="
---
## RETRY INFORMATION
**This is attempt #$CURRENT_ATTEMPTS** for this story."
      PREV_NOTES=$(get_story_notes "$STORY_KEY")
      [ -n "$PREV_NOTES" ] && RETRY_CONTEXT="$RETRY_CONTEXT
**Previous block reason:** $PREV_NOTES"
      RECORD_FILE="$RUNTIME_DIR/story-${STORY_KEY}-record.md"
      if [ -f "$RECORD_FILE" ]; then
        AMELIA_GUIDANCE=$(sed -n '/^## Amelia Guidance/,/^## /p' "$RECORD_FILE" | head -n -1)
        [ -n "$AMELIA_GUIDANCE" ] && RETRY_CONTEXT="$RETRY_CONTEXT
$AMELIA_GUIDANCE"
      fi
      RETRY_CONTEXT="$RETRY_CONTEXT
**Try a different approach than before.**"
    fi

    # Build prompt (re-reads PROGRESS.md each iteration for fresh relay notes)
    USER_PROMPT="## Current Progress
$(cat "$PROGRESS_FILE")
---
## Your Story
$(cat "$STORY_FILE")
$RETRY_CONTEXT"

    # ─── Execute: fresh claude -p ───
    HEAD_BEFORE=$(git rev-parse HEAD)
    STORY_START=$(date +%s)
    OUTPUT=$(env -u CLAUDECODE claude -p "$USER_PROMPT" \
      --append-system-prompt "$STATIC_CONTEXT" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "Bash,Read,Edit,Write,Grep,Glob" \
      --output-format text \
      2>&1) || true
    STORY_END=$(date +%s)
    STORY_DURATION=$(( STORY_END - STORY_START ))

    # ─── Parse completion signal ───
    if echo "$OUTPUT" | grep -q "<promise>STORY-${STORY_KEY}-DONE</promise>"; then
      echo "  ✅ Story $STORY_KEY — DONE (${STORY_DURATION}s, session $((CONTINUATIONS + 1)))"
      update_story_status "$STORY_KEY" "done" "completed $(timestamp) (${STORY_DURATION}s)"
      update_sprint_status "$STORY_KEY" "done"
      COMPLETED=$((COMPLETED + 1))
      STORIES_SINCE_REVIEW=$((STORIES_SINCE_REVIEW + 1))

      SUMMARY=$(echo "$OUTPUT" | sed -n '/^SUMMARY:/,/^<promise>/p' | head -n -1)
      [ -n "$SUMMARY" ] && append_relay_notes "### Story $STORY_KEY
$SUMMARY"

      { echo "# Story $STORY_KEY — Execution Record"; echo ""; echo "**Status:** done"; echo "**Completed:** $(timestamp)"; echo "**Duration:** ${STORY_DURATION}s"; echo "**Sessions:** $((CONTINUATIONS + 1))"; echo ""; [ -n "$SUMMARY" ] && { echo "## Summary"; echo "$SUMMARY"; echo ""; }; } > "$RUNTIME_DIR/story-${STORY_KEY}-record.md"

      # Post-DONE review
      if [ "$REVIEW_EVERY" -gt 0 ] && [ "$STORIES_SINCE_REVIEW" -ge "$REVIEW_EVERY" ] && [ -f "$AMELIA_PROMPT" ]; then
        echo "  🔍 Periodic Amelia review..."
        STORIES_SINCE_REVIEW=0
        AMELIA_OUTPUT=$(env -u CLAUDECODE claude -p "## Periodic Review (after Story $STORY_KEY)
Verify ACs met and no drift.
## Progress
$(cat "$PROGRESS_FILE")
## Recent Git History
$(git log --oneline -20)
## Story
$(cat "$STORY_FILE")" \
          --append-system-prompt "$(cat "$AMELIA_PROMPT")" \
          --max-turns "$AMELIA_MAX_TURNS" \
          --allowedTools "Read,Grep,Glob,Bash" \
          --output-format text 2>&1) || true

        VERDICT=$(parse_json_field "$AMELIA_OUTPUT" "action")
        if [ "$VERDICT" = "halt" ]; then echo "  🛑 Amelia: HALT — $(parse_json_field "$AMELIA_OUTPUT" "reason")"; STORY_RESULT="halt"; break; fi
        RELAY=$(parse_json_field "$AMELIA_OUTPUT" "relay_notes")
        [ -n "$RELAY" ] && append_relay_notes "### Amelia Review (after $STORY_KEY)
$RELAY"
      fi

      STORY_RESULT="done"
      break  # inner loop — story complete, move to next story

    elif echo "$OUTPUT" | grep -q "<promise>STORY-${STORY_KEY}-BLOCKED:"; then
      BLOCK_REASON=$(echo "$OUTPUT" | grep -o "<promise>STORY-${STORY_KEY}-BLOCKED:[^<]*</promise>" | sed "s/<promise>STORY-${STORY_KEY}-BLOCKED://;s/<\/promise>//")
      echo "  🛑 Story $STORY_KEY — BLOCKED: $BLOCK_REASON (${STORY_DURATION}s)"
      update_story_status "$STORY_KEY" "blocked" "$BLOCK_REASON"
      update_sprint_status "$STORY_KEY" "blocked"
      BLOCKED=$((BLOCKED + 1))

      RECORD_FILE="$RUNTIME_DIR/story-${STORY_KEY}-record.md"
      { echo "# Story $STORY_KEY — Execution Record"; echo ""; echo "**Status:** blocked"; echo "**Blocked:** $(timestamp)"; echo "**Duration:** ${STORY_DURATION}s"; echo "**Block reason:** $BLOCK_REASON"; echo ""; } > "$RECORD_FILE"

      # Call Amelia
      if [ -f "$AMELIA_PROMPT" ]; then
        echo "  🔍 Calling Amelia for review..."
        AMELIA_OUTPUT=$(env -u CLAUDECODE claude -p "## Progress
$(cat "$PROGRESS_FILE")
## Blockers
$(cat "$BLOCKERS_FILE")
## Recent Git History
$(git log --oneline -20)
## Blocked Story
$(cat "$STORY_FILE")" \
          --append-system-prompt "$(cat "$AMELIA_PROMPT")" \
          --max-turns "$AMELIA_MAX_TURNS" \
          --allowedTools "Read,Grep,Glob,Bash" \
          --output-format text 2>&1) || true

        VERDICT=$(parse_json_field "$AMELIA_OUTPUT" "action")
        case "$VERDICT" in
          retry)
            echo "  🔄 Amelia: retry with guidance"
            GUIDANCE=$(parse_json_field "$AMELIA_OUTPUT" "guidance")
            [ -n "$GUIDANCE" ] && { echo "## Amelia Guidance (attempt $CURRENT_ATTEMPTS)"; echo ""; echo "$GUIDANCE"; echo ""; } >> "$RECORD_FILE"
            RELAY=$(parse_json_field "$AMELIA_OUTPUT" "relay_notes")
            [ -n "$RELAY" ] && append_relay_notes "### Amelia Review (retry $STORY_KEY)
$RELAY"
            update_story_status "$STORY_KEY" "pending" "retry after review"
            update_sprint_status "$STORY_KEY" "in-progress"
            ;;
          skip)
            echo "  ⏭  Amelia: skip"
            update_story_status "$STORY_KEY" "skipped" "skipped by review"
            update_sprint_status "$STORY_KEY" "ready-for-dev"
            SKIP_LIST=$(parse_json_array_field "$AMELIA_OUTPUT" "skip_stories")
            if [ -n "$SKIP_LIST" ]; then
              echo "  ⏭  Also skipping: $SKIP_LIST"
              for SK in $SKIP_LIST; do
                update_story_status "$SK" "skipped" "depends on blocked $STORY_KEY"
                update_sprint_status "$SK" "ready-for-dev"
              done
            fi
            ;;
          halt)
            echo "  🛑 Amelia: HALT — $(parse_json_field "$AMELIA_OUTPUT" "reason")"
            STORY_RESULT="halt"
            ;;
          *)
            echo "  ⚠️  Could not parse Amelia's verdict — halting pipeline for safety."
            echo "$AMELIA_OUTPUT" > "$RUNTIME_DIR/amelia-debug-${STORY_KEY}.txt"
            STORY_RESULT="halt"
            ;;
        esac
      else
        echo "  ⚠️  Amelia prompt not found — halting pipeline (sequential dependencies)."
        STORY_RESULT="halt"
      fi

      STORY_RESULT="${STORY_RESULT:-blocked}"
      break  # inner loop — blocked, let outer loop decide

    else
      # ─── Max turns or unexpected exit — check if progress was made ───
      HEAD_AFTER=$(git rev-parse HEAD)
      COMMITS_MADE=$(git rev-list --count "$HEAD_BEFORE".."$HEAD_AFTER" 2>/dev/null || echo 0)
      echo "$OUTPUT" > "$RUNTIME_DIR/ralph-debug-${STORY_KEY}.txt"

      # Clean up uncommitted partial work (mid-task state is unreliable)
      [ -n "$(git status --porcelain)" ] && { echo "  🧹 Reverting uncommitted changes..."; git checkout .; }

      if [ "$COMMITS_MADE" -gt 0 ] && [ "$CONTINUATIONS" -lt "$MAX_CONTINUATIONS" ]; then
        # Progress was made — continuation, not a block
        CONTINUATIONS=$((CONTINUATIONS + 1))
        echo "  ⏱  Story $STORY_KEY — max turns, but $COMMITS_MADE commit(s) made (${STORY_DURATION}s)"
        echo "  🔄 Launching continuation $CONTINUATIONS/$MAX_CONTINUATIONS..."
        increment_attempts "$STORY_KEY"
        append_relay_notes "### Story $STORY_KEY — continuation $CONTINUATIONS
- Commits this session: $COMMITS_MADE"
        update_story_status "$STORY_KEY" "in-progress" "continuation $CONTINUATIONS/$MAX_CONTINUATIONS"
        continue  # inner while loop — re-run same story with fresh instance

      else
        if [ "$COMMITS_MADE" -eq 0 ]; then
          echo "  ⏱  Story $STORY_KEY — max turns, NO commits made (${STORY_DURATION}s)"
          echo "  🛑 No progress — this is a real block."
        else
          echo "  ⏱  Story $STORY_KEY — exhausted $MAX_CONTINUATIONS continuations (${STORY_DURATION}s)"
          echo "  🛑 Story too large for automated execution."
        fi
        update_story_status "$STORY_KEY" "blocked" "max-turns, no progress $(timestamp)"
        update_sprint_status "$STORY_KEY" "blocked"
        BLOCKED=$((BLOCKED + 1))
        STORY_RESULT="blocked"
        break  # inner loop
      fi
    fi
  done  # inner while loop (continuations)

  # Check if we need to halt the outer pipeline
  if [ "$STORY_RESULT" = "halt" ] || [ "$STORY_RESULT" = "blocked" ]; then
    echo "  🛑 Halting pipeline — downstream stories depend on this one."
    break  # outer for loop
  fi

  echo ""
done

# ─── Final Report ───
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Ralph Wiggum Executor — Epic $EPIC — COMPLETE"
echo "═══════════════════════════════════════════════════"
echo "  ✅ Completed: $COMPLETED"
echo "  🛑 Blocked:   $BLOCKED"
echo "  ⏭  Skipped:   $SKIPPED"
echo "  📊 Total:     ${#STORY_FILES[@]}"
echo ""
echo "  Branch: $(git branch --show-current)"
echo "  Commits: $(git rev-list --count HEAD ^main 2>/dev/null || echo 'N/A')"
echo "  Finished: $(timestamp)"
echo ""
echo "  Progress: $PROGRESS_FILE"
[ -f "$BLOCKERS_FILE" ] && [ "$BLOCKED" -gt 0 ] && echo "  Blockers: $BLOCKERS_FILE"
echo "═══════════════════════════════════════════════════"
