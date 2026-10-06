#!/usr/bin/env bash
set -euo pipefail

requested_model="${1:-}"

if [[ -z "$requested_model" ]]; then
  printf 'Usage: %s <model-id-or-alias>\n' "$0" >&2
  exit 2
fi

if ! kimi_path="$(command -v kimi 2>&1)"; then
  printf 'Kimi Code CLI is not installed or not on PATH.\n' >&2
  exit 3
fi

if ! jq_path="$(command -v jq 2>&1)"; then
  printf 'jq is required to resolve Kimi model aliases safely.\n' >&2
  printf 'Install jq before running this skill.\n' >&2
  exit 4
fi

provider_timeout_seconds="${KIMI_REVIEW_PROVIDER_TIMEOUT_SECONDS:-30}"
if [[ ! "$provider_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  provider_timeout_seconds=30
fi
provider_timeout_command=()
if gtimeout_path="$(command -v gtimeout 2>/dev/null)"; then
  provider_timeout_command=("$gtimeout_path" -k 5s "$provider_timeout_seconds")
elif timeout_path="$(command -v timeout 2>/dev/null)"; then
  provider_timeout_command=("$timeout_path" -k 5s "$provider_timeout_seconds")
fi

provider_json=""
if (( ${#provider_timeout_command[@]} > 0 )); then
  if ! provider_json="$("${provider_timeout_command[@]}" kimi provider list --json)"; then
    printf 'Unable to read Kimi provider catalog. Run `kimi provider list` and `kimi login`.\n' >&2
    exit 5
  fi
elif ! provider_json="$(kimi provider list --json)"; then
  printf 'Unable to read Kimi provider catalog. Run `kimi provider list` and `kimi login`.\n' >&2
  exit 5
fi

schema_check=""
if ! schema_check="$(printf '%s' "$provider_json" | jq -e '(.models | type) == "object" and (.models | length) > 0' 2>/dev/null)"; then
  printf 'Invalid provider catalog: expected a non-empty models object.\n' >&2
  exit 6
fi

candidates_json="$(
  printf '%s' "$provider_json" |
    jq -c --arg id "$requested_model" '
      .models | keys as $keys |
      if ($keys | index($id)) != null then
        [$id]
      else
        [$keys[] | select(endswith("/" + $id))]
      end
    '
)"
candidate_count="$(printf '%s' "$candidates_json" | jq 'length')"

case "$candidate_count" in
  0)
    printf 'Model alias not found: %s\n' "$requested_model" >&2
    exit 7
    ;;
  1)
    printf '%s\n' "$(printf '%s' "$candidates_json" | jq -r '.[0]')"
    ;;
  *)
    printf 'Ambiguous model alias: %s\n' "$requested_model" >&2
    printf '%s' "$candidates_json" | jq -r '.[] | "  - " + .' >&2
    printf 'Set KIMI_REVIEW_MODEL to one exact configured alias.\n' >&2
    exit 8
    ;;
esac
