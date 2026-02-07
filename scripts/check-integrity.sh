#!/bin/bash
# File Integrity Monitoring for OpenClaw Workspace
# Checks critical files for unauthorized modifications

WORKSPACE="$HOME/.openclaw/workspace"
cd "$WORKSPACE" || exit 1

CRITICAL_FILES=(
  "SOUL.md"
  "MEMORY.md"
  "IDENTITY.md"
  "USER.md"
  ".agent-private-key-SECURE"
  "AGENTS.md"
  "HEARTBEAT.md"
)

VIOLATIONS=0
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== File Integrity Check: $TIMESTAMP ==="

# Check core files
for file in "${CRITICAL_FILES[@]}"; do
  if [ -f "$file" ]; then
    CURRENT=$(sha256sum "$file" | cut -d' ' -f1)
    BASELINE=$(cat ".integrity/$file.sha256" 2>/dev/null | cut -d' ' -f1)
    
    if [ -z "$BASELINE" ]; then
      echo "⚠️  WARNING: No baseline for $file (run initial hash generation)"
      VIOLATIONS=$((VIOLATIONS + 1))
    elif [ "$CURRENT" != "$BASELINE" ]; then
      echo "🚨 VIOLATION: $file modified without authorization!"
      echo "   Current:  $CURRENT"
      echo "   Baseline: $BASELINE"
      VIOLATIONS=$((VIOLATIONS + 1))
      
      # Log to security incidents
      echo "## File Integrity Violation: $file" >> memory/security-incidents.md
      echo "**Date:** $TIMESTAMP" >> memory/security-incidents.md
      echo "**File:** $file" >> memory/security-incidents.md
      echo "**Current Hash:** $CURRENT" >> memory/security-incidents.md
      echo "**Baseline Hash:** $BASELINE" >> memory/security-incidents.md
      echo "**Action Required:** Review changes and update baseline if legitimate" >> memory/security-incidents.md
      echo "" >> memory/security-incidents.md
    fi
  fi
done

# Check skill files
find skills/ -name "SKILL.md" -type f | while read -r skill; do
  HASH_FILE=".integrity/$(echo "$skill" | tr / _).sha256"
  if [ -f "$HASH_FILE" ]; then
    CURRENT=$(sha256sum "$skill" | cut -d' ' -f1)
    BASELINE=$(cat "$HASH_FILE" | cut -d' ' -f1)
    
    if [ "$CURRENT" != "$BASELINE" ]; then
      echo "🚨 VIOLATION: $skill modified!"
      echo "   Current:  $CURRENT"
      echo "   Baseline: $BASELINE"
      VIOLATIONS=$((VIOLATIONS + 1))
      
      # Log to security incidents
      echo "## Skill Modification: $skill" >> memory/security-incidents.md
      echo "**Date:** $TIMESTAMP" >> memory/security-incidents.md
      echo "**Skill:** $skill" >> memory/security-incidents.md
      echo "**Current Hash:** $CURRENT" >> memory/security-incidents.md
      echo "**Baseline Hash:** $BASELINE" >> memory/security-incidents.md
      echo "**Risk:** CRITICAL - Skill may be poisoned" >> memory/security-incidents.md
      echo "**Action:** Quarantine skill and investigate" >> memory/security-incidents.md
      echo "" >> memory/security-incidents.md
    fi
  fi
done

if [ $VIOLATIONS -gt 0 ]; then
  echo ""
  echo "⚠️  $VIOLATIONS file(s) modified without authorization"
  echo "Review changes and update baseline if legitimate:"
  echo "  sha256sum [file] > .integrity/[file].sha256"
  exit 1
fi

echo "✅ All files integrity verified ($(($(ls -1 .integrity/*.sha256 | wc -l))) files checked)"
exit 0
