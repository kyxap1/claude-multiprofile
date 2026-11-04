#!/usr/bin/env bash
# Regenerates docs/statusline.png from the real statusline.sh with made-up
# profiles, repos and emails. Everything runs in Docker; run it after changing
# the statusline.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
docker build -q -t claude-multiprofile-screenshot docs/screenshot >/dev/null
docker run --rm -v "$PWD:/repo:ro" -v "$PWD/docs:/out" claude-multiprofile-screenshot \
  bash /repo/docs/screenshot/render.sh
