#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
work/m0b/VisionProbe --batch work/m0b/vision-batch-private.json work/m0b/vision-real-private.json
