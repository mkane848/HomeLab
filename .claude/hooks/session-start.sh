#!/bin/bash
# Installs PowerShell (pwsh) in remote/web sessions so AGENTS.md's own
# PowerShell syntax-check convention (ParseFile against every edited .ps1)
# can actually run here - this repo is mostly bash/PowerShell scripts, not
# an app with a package manifest, so pwsh itself is the one real dependency.
# Only needed remotely: a local Claude Code CLI session on the desktop
# already has real Windows PowerShell.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if command -v pwsh >/dev/null 2>&1; then
  exit 0
fi

PWSH_VERSION="7.4.6"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) PWSH_ARCH="x64" ;;
  aarch64) PWSH_ARCH="arm64" ;;
  *) echo "session-start.sh: unsupported arch $ARCH, skipping pwsh install" >&2; exit 0 ;;
esac

TARBALL="powershell-${PWSH_VERSION}-linux-${PWSH_ARCH}.tar.gz"
URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/${TARBALL}"

TMP="$(mktemp -d)"
if ! curl -sSL -o "$TMP/$TARBALL" "$URL"; then
  echo "session-start.sh: failed to download pwsh, skipping" >&2
  rm -rf "$TMP"
  exit 0
fi

mkdir -p /opt/microsoft/powershell/7
tar zxf "$TMP/$TARBALL" -C /opt/microsoft/powershell/7
chmod +x /opt/microsoft/powershell/7/pwsh
ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
rm -rf "$TMP"

pwsh --version
