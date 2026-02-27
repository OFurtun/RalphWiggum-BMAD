#!/usr/bin/env bash
set -euo pipefail

# RalphWiggum-BMAD Installer
# Installs Ralph into a target project's .claude/skills/ralph/

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "═══════════════════════════════════════════════════"
echo "  RalphWiggum-BMAD Installer"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── Step 1: Pick target project ───
echo "── Target Project ─────────────────────────────"
echo ""

if [ -n "${1:-}" ]; then
  TARGET_DIR="$1"
else
  read -rp "  Project directory to install into: " TARGET_DIR
fi

# Expand ~ and resolve path
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: Directory does not exist: $TARGET_DIR"
  exit 1
}

if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "WARNING: $TARGET_DIR is not a git repository."
  read -rp "  Continue anyway? [y/N]: " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "  Installing into: $TARGET_DIR"
echo ""

# ─── Step 2: Detect BMAD ───
BMAD_DETECTED=false
if [ -d "$TARGET_DIR/_bmad-output/implementation-artifacts" ] || [ -d "$TARGET_DIR/_bmad-output/planning-artifacts" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD project structure"
elif [ -d "$TARGET_DIR/_bmad" ] || [ -d "$TARGET_DIR/_bmad-project" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD installation (no output yet)"
else
  echo "  No BMAD installation detected — using generic defaults"
fi
echo ""

# ─── Helper ───
ask() {
  local prompt="$1"
  local default="$2"
  local result
  read -rp "  $prompt [$default]: " result
  echo "${result:-$default}"
}

# ─── Step 3: Configure paths ───
echo "── Story Files ──────────────────────────────────"
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  STORIES_DIR=$(ask "Stories directory (relative to project root)" "_bmad-output/implementation-artifacts")
else
  STORIES_DIR=$(ask "Stories directory (relative to project root)" "stories")
fi
echo ""

echo "── Project Context ──────────────────────────────"
echo "  A markdown file with coding standards, naming conventions."
echo "  Ralph uses this as ambient context for every story."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  PROJECT_CONTEXT=$(ask "Project context file (or 'none')" "_bmad-output/planning-artifacts/project-context.md")
else
  PROJECT_CONTEXT=$(ask "Project context file (or 'none')" "none")
fi
echo ""

echo "── Architecture Docs (Amelia only) ─────────────"
echo "  Full documentation Amelia reads when diagnosing blocks."
echo "  Ralph NEVER reads these — only Amelia."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  ARCHITECTURE_DOCS=$(ask "Architecture docs directory (or 'none')" "_bmad-output/planning-artifacts/architecture/")
else
  ARCHITECTURE_DOCS=$(ask "Architecture docs directory (or 'none')" "none")
fi
echo ""

echo "── Sprint Status ────────────────────────────────"
echo "  A YAML file tracking story statuses. Ralph keeps it in sync."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  SPRINT_STATUS=$(ask "Sprint status file (or 'none')" "_bmad-output/implementation-artifacts/sprint-status.yaml")
else
  SPRINT_STATUS=$(ask "Sprint status file (or 'none')" "none")
fi
echo ""

echo "── Runtime Directory ────────────────────────────"
echo "  Where Ralph stores progress, blockers, and execution records."
echo "  Auto-added to .gitignore."
echo ""
RUNTIME_DIR=$(ask "Runtime directory" "_ralph")
echo ""

echo "── Commands ─────────────────────────────────────"
echo ""
TEST_CMD=$(ask "Test command" "npm run test")
CHECK_CMD=$(ask "Type check command" "npm run check")
LINT_CMD=$(ask "Lint command" "npm run lint")
echo ""

echo "── Tuning ───────────────────────────────────────"
echo ""
MAX_TURNS=$(ask "Max turns per story (claude -p)" "50")
AMELIA_MAX_TURNS=$(ask "Max turns for Amelia review" "20")
echo ""

# ─── Step 4: Install files ───
SKILL_DIR="$TARGET_DIR/.claude/skills/ralph"
mkdir -p "$SKILL_DIR/scripts"

echo "── Installing ─────────────────────────────────"

# Copy scripts and prompts
cp "$INSTALLER_DIR/scripts/ralph.sh" "$SKILL_DIR/scripts/ralph.sh"
cp "$INSTALLER_DIR/prompts/ralph-prompt.md" "$SKILL_DIR/scripts/ralph-prompt.md"
cp "$INSTALLER_DIR/prompts/amelia-review-prompt.md" "$SKILL_DIR/scripts/amelia-review-prompt.md"
cp "$INSTALLER_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
chmod +x "$SKILL_DIR/scripts/ralph.sh"

echo "  Copied: SKILL.md"
echo "  Copied: scripts/ralph.sh"
echo "  Copied: scripts/ralph-prompt.md"
echo "  Copied: scripts/amelia-review-prompt.md"

# ─── Step 5: Write config into the skill directory ───
cat > "$SKILL_DIR/ralph.config" <<CONF
# RalphWiggum-BMAD Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Project: $(basename "$TARGET_DIR")

# Story files
STORIES_DIR="$STORIES_DIR"

# Context
PROJECT_CONTEXT="$PROJECT_CONTEXT"
ARCHITECTURE_DOCS="$ARCHITECTURE_DOCS"
SPRINT_STATUS="$SPRINT_STATUS"

# Runtime
RUNTIME_DIR="$RUNTIME_DIR"

# Commands
TEST_CMD="$TEST_CMD"
CHECK_CMD="$CHECK_CMD"
LINT_CMD="$LINT_CMD"

# Tuning
MAX_TURNS=$MAX_TURNS
AMELIA_MAX_TURNS=$AMELIA_MAX_TURNS
CONF

echo "  Written: ralph.config"

# ─── Step 6: Update SKILL.md paths from config ───
# Patch SKILL.md with configured paths
sed -i "s|_bmad-output/implementation-artifacts|$STORIES_DIR|g" "$SKILL_DIR/SKILL.md"
sed -i "s|_bmad-output/planning-artifacts/project-context.md|$PROJECT_CONTEXT|g" "$SKILL_DIR/SKILL.md"
sed -i "s|_bmad-output/implementation-artifacts/sprint-status.yaml|$SPRINT_STATUS|g" "$SKILL_DIR/SKILL.md"

# Patch amelia prompt with architecture path
if [ "$ARCHITECTURE_DOCS" != "none" ]; then
  sed -i "s|_bmad-output/planning-artifacts/architecture/|$ARCHITECTURE_DOCS|g" "$SKILL_DIR/scripts/amelia-review-prompt.md"
fi

echo ""

# ─── Step 7: Ensure runtime dir gitignored ───
GITIGNORE="$TARGET_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ] || ! grep -q "^${RUNTIME_DIR}/" "$GITIGNORE" 2>/dev/null; then
  echo "${RUNTIME_DIR}/" >> "$GITIGNORE"
  echo "  Added ${RUNTIME_DIR}/ to .gitignore"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Installation complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Installed to: $SKILL_DIR/"
echo ""
echo "  Files:"
echo "    $SKILL_DIR/SKILL.md"
echo "    $SKILL_DIR/ralph.config"
echo "    $SKILL_DIR/scripts/ralph.sh"
echo "    $SKILL_DIR/scripts/ralph-prompt.md"
echo "    $SKILL_DIR/scripts/amelia-review-prompt.md"
echo ""
echo "  Usage:"
echo "    cd $TARGET_DIR"
echo "    /ralph 1                    # via Claude Code skill"
echo "    bash $SKILL_DIR/scripts/ralph.sh --epic 1   # direct"
echo ""
echo "  To reconfigure: re-run this installer or edit $SKILL_DIR/ralph.config"
echo "═══════════════════════════════════════════════════"
