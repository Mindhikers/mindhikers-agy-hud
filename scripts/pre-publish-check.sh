#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

echo "== MindHikers Pre-Publish Check =="

# 1. Hardcoded personal user paths in tracked or workspace source files
if grep -rnE --exclude="pre-publish-check.sh" '(/Users/|/home/|C:\\Users\\)' Sources Resources scripts tests README.md LICENSE CHANGELOG.md 2>/dev/null; then
  echo "[FAIL] Found hardcoded user paths!"
  FAIL=1
else
  echo "[PASS] No hardcoded user paths"
fi

# 2. Secret / token literals
if grep -rnE --exclude="pre-publish-check.sh" '(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)' Sources Resources scripts tests README.md 2>/dev/null; then
  echo "[FAIL] Found potential secret literal!"
  FAIL=1
else
  echo "[PASS] No secret or token literals"
fi

# 3. Verify zero outbound network / keychain / OAuth calls in app code
if grep -rnE '(googleapis\.com|oauth2|accounts\.google|find-generic-password|add-generic-password|state\.vscdb|remote-debugging-port)' Sources Resources 2>/dev/null; then
  echo "[FAIL] Found forbidden network/OAuth/Keychain/CDP references in app code!"
  FAIL=1
else
  echo "[PASS] Read-only boundary verified (no OAuth, Keychain, cloud API, or CDP)"
fi

# 4. Check untracked build artifacts / .DS_Store not staged
if git ls-files | grep -E '(\.DS_Store|^dist/|^\.build/)' >/dev/null 2>&1; then
  echo "[FAIL] Build artifacts or .DS_Store tracked in git!"
  FAIL=1
else
  echo "[PASS] No build artifacts or .DS_Store tracked"
fi

# 5. Check git history for deleted files (when commits exist)
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  DELETED=$(git log --all --diff-filter=D --summary | grep 'delete mode' || true)
  if [[ -n "$DELETED" ]]; then
    echo "[WARN] Deleted files exist in git history; review before making public:"
    echo "$DELETED"
  else
    echo "[PASS] No deleted files in git history"
  fi
else
  echo "[PASS] Fresh repo (no commits yet)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "== PRE-PUBLISH CHECK FAILED =="
  exit 1
fi
echo "== ALL PRE-PUBLISH CHECKS PASSED =="
