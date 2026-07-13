#!/usr/bin/env bash
# Structural validation for the kubernetes-mastery plugin.
# Checks: plugin.json is valid JSON; every SKILL.md has name+description
# frontmatter; every referenced markdown file resolves (no dead links).
# ponytail: intentionally structural only — it does not judge content quality.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
note() { printf '  %s\n' "$1"; }
err()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# 1. plugin.json parses as JSON
manifest="$ROOT/.claude-plugin/plugin.json"
if [[ ! -f "$manifest" ]]; then
  err ".claude-plugin/plugin.json missing"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('$manifest'))" 2>/dev/null \
    && note "plugin.json: valid JSON" || err "plugin.json: invalid JSON"
else
  note "plugin.json: skipped JSON parse (python3 not found)"
fi

# 2. each skill has name + description frontmatter
shopt -s nullglob
for skill in "$ROOT"/skills/*/SKILL.md; do
  rel="${skill#$ROOT/}"
  fm="$(awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$skill")"
  grep -qE '^name:[[:space:]]*\S' <<<"$fm"        || err "$rel: missing 'name' in frontmatter"
  grep -qE '^description:[[:space:]]*\S' <<<"$fm"  || err "$rel: missing 'description' in frontmatter"
  [[ -n "$fm" ]] && note "$rel: frontmatter ok"
done

# 3. no dead reference links (markdown paths under references/ and ${CLAUDE_PLUGIN_ROOT})
while IFS= read -r md; do
  # ${CLAUDE_PLUGIN_ROOT}/some/path.md
  grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+\.md' "$md" | sed 's#\${CLAUDE_PLUGIN_ROOT}/##' | while read -r p; do
    [[ -f "$ROOT/$p" ]] || err "${md#$ROOT/}: dead link -> $p"
  done
  # bare references/<name>.md relative to the skill dir
  d="$(dirname "$md")"
  grep -oE '(^|[^A-Za-z0-9._/-])references/[A-Za-z0-9._/-]+\.md' "$md" | grep -oE 'references/[A-Za-z0-9._/-]+\.md' | while read -r p; do
    [[ -f "$d/$p" || -f "$ROOT/$p" ]] || err "${md#$ROOT/}: dead link -> $p"
  done
done < <(find "$ROOT" -name '*.md')

if [[ $fail -eq 0 ]]; then
  echo "OK: kubernetes-mastery validation passed"
else
  echo "kubernetes-mastery validation FAILED"
fi
exit $fail
