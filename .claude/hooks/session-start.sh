#!/bin/bash
# Installs PowerShell (pwsh) in remote/web sessions so AGENTS.md's own
# PowerShell syntax-check convention (ParseFile against every edited .ps1)
# can actually run here - this repo is mostly bash/PowerShell scripts, not
# an app with a package manifest, so pwsh itself is the one real dependency.
# Only needed remotely: a local Claude Code CLI session on the desktop
# already has real Windows PowerShell.
#
# The tarball is checked against a pinned sha256 before anything is unpacked
# (2026-11-24; the 2026-11-09 audit's supply-chain finding). The pins are the
# release's own hashes.sha256 for v7.4.6, and they matched a fresh download of
# each tarball. A mismatch installs nothing. Moving to another version means
# new pins from that release's hashes.sha256.
#
# Test overrides (tests/test-session-start-hook.ps1): PWSH_URL, PWSH_INSTALL_DIR,
# PWSH_LINK. The pin does not move with them: whatever the URL, only a file
# with the pinned hash is unpacked.
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
  x86_64)
    PWSH_ARCH="x64"
    PWSH_SHA256="6f6015203c47806c5cc444c19d8ed019695e610fbd948154264bf9ca8e157561" ;;
  aarch64)
    PWSH_ARCH="arm64"
    PWSH_SHA256="c0159b03e85f44ae1e7697818a011558da6c813d0aae848bf5ac13bf435d8624" ;;
  *) echo "session-start.sh: unsupported arch $ARCH, skipping pwsh install" >&2; exit 0 ;;
esac

TARBALL="powershell-${PWSH_VERSION}-linux-${PWSH_ARCH}.tar.gz"
URL="${PWSH_URL:-https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/${TARBALL}}"
INSTALL_DIR="${PWSH_INSTALL_DIR:-/opt/microsoft/powershell/7}"
LINK="${PWSH_LINK:-/usr/local/bin/pwsh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! curl -fsSL -o "$TMP/$TARBALL" "$URL"; then
  echo "session-start.sh: failed to download pwsh, skipping" >&2
  exit 0
fi

GOT="$(sha256sum "$TMP/$TARBALL" | cut -d' ' -f1)"
if [ "$GOT" != "$PWSH_SHA256" ]; then
  echo "session-start.sh: REFUSED to install pwsh: $TARBALL has sha256 $GOT, expected the pinned $PWSH_SHA256. Nothing was installed." >&2
  exit 0
fi

mkdir -p "$INSTALL_DIR"
tar zxf "$TMP/$TARBALL" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/pwsh"
ln -sf "$INSTALL_DIR/pwsh" "$LINK"

"$LINK" --version
