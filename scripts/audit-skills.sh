#!/bin/bash
# Skill Security Audit Script
# Part of openclaw-defender

SKILL_PATH="$1"

if [ -z "$SKILL_PATH" ]; then
  echo "Usage: $0 <path-to-skill-directory>"
  exit 1
fi

if [ ! -d "$SKILL_PATH" ]; then
  echo "Error: $SKILL_PATH is not a directory"
  exit 1
fi

SKILL_NAME=$(basename "$SKILL_PATH")
SKILL_MD="$SKILL_PATH/SKILL.md"

echo "=== OpenClaw Defender: Skill Security Audit ==="
echo "Skill: $SKILL_NAME"
echo "Path: $SKILL_PATH"
echo ""

if [ ! -f "$SKILL_MD" ]; then
  echo "❌ FAIL: No SKILL.md found"
  exit 1
fi

VIOLATIONS=0

# Check 1: Base64 encoding
echo "--- Checking for base64 encoding ---"
if grep -qi "base64" "$SKILL_MD"; then
  echo "⚠️  WARNING: Base64 pattern detected"
  grep -n "base64" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 1))
else
  echo "✓ PASS"
fi

# Check 2: Suspicious downloads
echo ""
echo "--- Checking for suspicious downloads ---"
if grep -iE "(curl|wget).*\|.*bash" "$SKILL_MD"; then
  echo "🚨 CRITICAL: curl|bash pattern detected"
  grep -n -iE "(curl|wget).*\|.*bash" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 5))
elif grep -iE "\.(zip|exe|dmg|pkg)" "$SKILL_MD" | grep -qi "password"; then
  echo "🚨 CRITICAL: Password-protected archive detected"
  VIOLATIONS=$((VIOLATIONS + 5))
elif grep -iE "(curl|wget|download)" "$SKILL_MD"; then
  echo "⚠️  WARNING: Download detected (review manually)"
  grep -n -iE "(curl|wget|download)" "$SKILL_MD" | head -5
  VIOLATIONS=$((VIOLATIONS + 1))
else
  echo "✓ PASS"
fi

# Check 3: Credential requests
echo ""
echo "--- Checking for credential requests ---"
if grep -iE "(echo|print|log).*\$.*(_KEY|_TOKEN|_PASSWORD|_SECRET)" "$SKILL_MD"; then
  echo "🚨 CRITICAL: Credential echo/print detected"
  grep -n -iE "(echo|print|log).*\$.*(_KEY|_TOKEN|_PASSWORD|_SECRET)" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 5))
else
  echo "✓ PASS"
fi

# Check 4: Jailbreak patterns
echo ""
echo "--- Checking for jailbreak patterns ---"
if grep -iE "(ignore.*(previous|above|prior).*(instruction|command|prompt))" "$SKILL_MD"; then
  echo "🚨 CRITICAL: Prompt injection detected"
  grep -n -iE "(ignore.*(previous|above|prior).*(instruction|command|prompt))" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 5))
elif grep -iE "(you are now|system.?prompt|DAN mode)" "$SKILL_MD"; then
  echo "🚨 CRITICAL: Jailbreak attempt detected"
  grep -n -iE "(you are now|system.?prompt|DAN mode)" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 5))
else
  echo "✓ PASS"
fi

# Check 5: Unicode tricks
echo ""
echo "--- Checking for unicode steganography ---"
if grep -P "[\x{200B}-\x{200D}\x{FEFF}\x{2060}]" "$SKILL_MD"; then
  echo "🚨 CRITICAL: Invisible Unicode characters detected"
  VIOLATIONS=$((VIOLATIONS + 5))
else
  echo "✓ PASS"
fi

# Check 6: Memory poisoning
echo ""
echo "--- Checking for memory poisoning attempts ---"
if grep -iE "(SOUL|MEMORY|IDENTITY)\.md" "$SKILL_MD" | grep -iE "(modify|change|update|edit|write)"; then
  echo "🚨 CRITICAL: Memory modification detected"
  grep -n -iE "(SOUL|MEMORY|IDENTITY)\.md" "$SKILL_MD"
  VIOLATIONS=$((VIOLATIONS + 5))
else
  echo "✓ PASS"
fi

# Check 7: Known malicious infrastructure
echo ""
echo "--- Checking for known malicious infrastructure ---"
if grep -E "91\.92\.242\.30" "$SKILL_MD"; then
  echo "🚨 CRITICAL: Known C2 server detected (91.92.242.30)"
  VIOLATIONS=$((VIOLATIONS + 10))
else
  echo "✓ PASS"
fi

# Summary
echo ""
echo "=== Audit Summary ==="
echo "Total violations: $VIOLATIONS"

if [ $VIOLATIONS -eq 0 ]; then
  echo "✅ PASS: No security issues detected"
  exit 0
elif [ $VIOLATIONS -lt 5 ]; then
  echo "⚠️  WARN: Minor issues found (review manually)"
  exit 1
else
  echo "🚨 FAIL: CRITICAL security issues detected"
  echo "Recommendation: DO NOT INSTALL"
  exit 2
fi
