#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/dhu.ini"
USB_DEVICE="100000001eb9c1b6"

if [ -z "${DHU_PATH:-}" ]; then
    echo "error: DHU_PATH is not set" >&2
    echo "export DHU_PATH to the directory containing the desktop-head-unit binary" >&2
    exit 1
fi

if [ ! -x "${DHU_PATH}/desktop-head-unit" ]; then
    echo "error: desktop-head-unit not found or not executable at: ${DHU_PATH}/desktop-head-unit" >&2
    exit 1
fi

"${DHU_PATH}/desktop-head-unit" --usb="${USB_DEVICE}" --config="${CONFIG_FILE}"