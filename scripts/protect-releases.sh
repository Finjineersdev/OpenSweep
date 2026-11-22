#!/bin/bash
# SPDX-License-Identifier: MIT
#
# One time, by the owner (docs/RELEASING.md): the release job waits for your
# approval and runs only for v* tags, only an admin can create, move or
# delete v* tags, and the Sparkle key moves into the release environment.
# Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=Finjineersdev/OpenSweep
ME=$(gh api user --jq .id)

gh api -X PUT "repos/$REPO/environments/release" --jq '"environment: " + .name' --input - <<JSON
{"reviewers":[{"type":"User","id":$ME}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
if gh api "repos/$REPO/environments/release/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx 'v\*'; then
  echo "only tags: v* (already set)"
else
  gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" \
    -f name='v*' -f type=tag --jq '"only tags: " + .name'
fi
if gh api "repos/$REPO/rulesets" --jq '.[].name' | grep -qx "Release tags"; then
  echo "tag rule: already set"
else
  gh api -X POST "repos/$REPO/rulesets" --jq '"tag rule: " + .name' --input - <<'JSON'
{"name":"Release tags","target":"tag","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"},{"type":"non_fast_forward"}],
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}
JSON
fi
scripts/setup-sparkle-key.sh
