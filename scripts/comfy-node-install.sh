#!/usr/bin/env bash
# comfy-node-install: install custom ComfyUI nodes and fail with non-zero
# exit code if any of them cannot be installed. On failure it prints the
# list of nodes that could not be installed and hints the user to consult
# https://registry.comfy.org/ for correct names.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: comfy-node-install <node1> [<node2> …]" >&2
  exit 64  # EX_USAGE
fi

log=$(mktemp)

# run installation – some modes return non-zero even on success, so we
# ignore the exit status and rely on log parsing instead.
set +e
comfy node install --mode=remote "$@" 2>&1 | tee "$log"
cli_status=$?
set -e

# extract node names that failed to install (one per line, uniq-sorted)
failed_nodes=$(grep -oP "(?<=An error occurred while installing ')[^']+" "$log" | sort -u || true)

# Fallback: capture names from "Node '<name>@' not found" lines if previous grep found nothing
if [[ -z "$failed_nodes" ]]; then
  failed_nodes=$(grep -oP "(?<=Node ')[^@']+" "$log" | sort -u || true)
fi

if [[ -n "$failed_nodes" ]]; then
  echo "Comfy node installation failed for the following nodes:" >&2
  echo "$failed_nodes" | while read -r n; do echo "  • $n" >&2 ; done
  echo >&2
  echo "Please verify the node names at https://registry.comfy.org/ and try again." >&2
  exit 1
fi

# If we reach here no failed nodes were detected. Warn if CLI exit status
# was non-zero but treat it as success.
if [[ $cli_status -ne 0 ]]; then
  echo "Warning: comfy node install exited with status $cli_status but no errors were detected in the log — assuming success." >&2
fi

# Workaround for runpod-workers/worker-comfyui#237: `comfy node install`
# resolves the workspace python (VIRTUAL_ENV or /comfyui/.venv) and installs
# the nodes' pip dependencies there, but start.sh launches ComfyUI with
# /opt/venv's python. Nodes whose dependencies landed in the wrong venv fail
# to import at startup and are never registered ("missing" custom nodes).
# Mirror ComfyUI's and every installed custom node's requirements into the
# launch venv (/opt/venv), same as the base image's own DR-1170 dep loop —
# which runs before downstream nodes are installed and therefore misses them.
# The transformers/huggingface-hub pin mirrors the base image: ComfyUI
# declares no upper bound, so fresh resolves can pull breaking 5.x/1.x
# releases.
mirror_log=$(mktemp)
if ! uv pip install --python /opt/venv/bin/python \
      -r /comfyui/requirements.txt \
      $(for r in /comfyui/custom_nodes/*/requirements.txt; do [ -f "$r" ] && echo -n " -r $r"; done) \
      "transformers>=4.50.3,<5" "huggingface-hub<1.0" >"$mirror_log" 2>&1; then
  echo "Error: failed to mirror custom node dependencies into /opt/venv:" >&2
  tail -n 40 "$mirror_log" >&2
  exit 1
fi
rm -f "$mirror_log"

exit 0 