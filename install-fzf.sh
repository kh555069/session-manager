#!/usr/bin/env bash
# ╭──────────────────────────────────────────────────────╮
# │  install-fzf.sh -- Download fzf binary for tm.sh    │
# ╰──────────────────────────────────────────────────────╯
set -euo pipefail

# ─── Configuration ────────────────────────────────────
readonly FZF_VERSION="0.68.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect OS and architecture
_os=$(uname -s | tr '[:upper:]' '[:lower:]')
_arch=$(uname -m)
case "$_os" in
  darwin) _os="darwin" ;;
  linux)  _os="linux" ;;
  *)      echo "Error: unsupported OS: $_os" >&2; exit 1 ;;
esac
case "$_arch" in
  x86_64|amd64)  _arch="amd64" ;;
  arm64|aarch64) _arch="arm64" ;;
  *)             echo "Error: unsupported architecture: $_arch" >&2; exit 1 ;;
esac
readonly ARCH="${_os}_${_arch}"
readonly FILENAME="fzf-${FZF_VERSION}-${ARCH}.tar.gz"
readonly URL="https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/${FILENAME}"

# ─── Pre-flight checks ───────────────────────────────
if [[ -x "${SCRIPT_DIR}/fzf" ]]; then
  current_version=$("${SCRIPT_DIR}/fzf" --version 2>/dev/null | awk '{print $1}' || echo "unknown")
  echo "fzf already exists (version: ${current_version})"
  read -rp "Overwrite? (y/N): " answer
  if [[ "${answer,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

if ! command -v curl &>/dev/null; then
  echo "Error: curl is required but not found." >&2
  exit 1
fi

# ─── Download ─────────────────────────────────────────
echo "Downloading fzf v${FZF_VERSION} (${ARCH})..."
curl -fLO "${URL}"

# ─── Extract ──────────────────────────────────────────
echo "Extracting ${FILENAME}..."
tar xzf "${FILENAME}" -C "${SCRIPT_DIR}"

# ─── Cleanup ──────────────────────────────────────────
echo "Removing archive..."
rm -f "${FILENAME}"

# ─── Verify ───────────────────────────────────────────
chmod +x "${SCRIPT_DIR}/fzf"
installed_version=$("${SCRIPT_DIR}/fzf" --version 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Done! fzf ${installed_version} installed at ${SCRIPT_DIR}/fzf"
