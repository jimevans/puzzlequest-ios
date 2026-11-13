#!/bin/bash
# Pins the app to a release of the PuzzleQuest API: downloads the release's
# description (openapi.json), live-update messages (live-updates.json), and,
# from 1.1, what push notifications carry (push-notifications.json) into api/, records the tag in api/VERSION, and writes the copy the client is
# generated from (see scripts/tolerant-openapi.jq for what it changes).
#
#   scripts/update-api.sh v1.0.1     # move to that release
#   scripts/update-api.sh            # re-apply the changes to the pinned one
#
# Needs the GitHub CLI (gh) for downloading, and jq.
set -euo pipefail

REPOSITORY=jimevans/therapypub-puzzlequest
ROOT=$(cd "$(dirname "$0")/.." && pwd)
API="$ROOT/api"
GENERATED_FROM="$ROOT/PuzzleQuestKit/Sources/PuzzleQuestAPI/openapi.json"

if [[ $# -gt 1 || ( $# -eq 1 && ! $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ) ]]; then
  echo "usage: $0 [vX.Y.Z]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  download=$(mktemp -d)
  trap 'rm -rf "$download"' EXIT
  gh release download "$1" --repo "$REPOSITORY" --pattern openapi.json \
    --pattern live-updates.json --pattern push-notifications.json --dir "$download"
  mv "$download/openapi.json" "$download/live-updates.json" "$API/"
  # Releases before 1.1 have no push notifications.
  if [[ -f "$download/push-notifications.json" ]]; then
    mv "$download/push-notifications.json" "$API/"
  fi
  echo "$1" > "$API/VERSION"
fi

jq --indent 2 -f "$ROOT/scripts/tolerant-openapi.jq" "$API/openapi.json" > "$GENERATED_FROM"
echo "API $(cat "$API/VERSION"): wrote ${GENERATED_FROM#"$ROOT/"}"
