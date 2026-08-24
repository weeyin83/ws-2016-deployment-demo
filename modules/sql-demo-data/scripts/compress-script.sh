#!/usr/bin/env bash
# Helper for the "external" data source in modules/sql-demo-data/main.tf.
# Reads {"script": "..."} JSON on stdin, gzip-compresses + base64-encodes the
# script, and writes {"compressed": "..."} JSON to stdout. This lets the full
# script be embedded in a CustomScriptExtension commandToExecute (which
# cmd.exe limits to 8191 characters) without any external file hosting.
#
# Requires: bash, jq, gzip, base64 (all present in this devcontainer).
set -euo pipefail

input="$(cat)"
script="$(jq -r '.script' <<<"$input")"
compressed="$(printf '%s' "$script" | gzip -9 -c | base64 -w0)"
jq -n --arg compressed "$compressed" '{compressed: $compressed}'
