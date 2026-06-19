#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-homebrew-tap.sh \
    --tap-dir <path> \
    --version <semver-without-v-prefix> \
    --sha256 <sha256> \
    [--source-repo <owner/repo>]

Example:
  update-homebrew-tap.sh \
    --tap-dir ./homebrew-tap \
    --version 1.2.3 \
    --sha256 abcdef... \
    --source-repo Futhark-AS/quedo
EOF
}

TAP_DIR=""
VERSION=""
SHA256=""
SOURCE_REPO="Futhark-AS/quedo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-dir)
      TAP_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --sha256)
      SHA256="$2"
      shift 2
      ;;
    --source-repo)
      SOURCE_REPO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TAP_DIR" || -z "$VERSION" || -z "$SHA256" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid SHA256 format: $SHA256" >&2
  exit 1
fi

mkdir -p "$TAP_DIR/Casks"

cat > "$TAP_DIR/Casks/quedo.rb" <<EOF
cask "quedo" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${SOURCE_REPO}/releases/download/v#{version}/Quedo.dmg",
      verified: "github.com/${SOURCE_REPO}/"
  name "Quedo"
  desc "Voice-to-text tool powered by Groq Whisper API"
  homepage "https://github.com/${SOURCE_REPO}"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Quedo.app"

  uninstall quit: "com.futhark.quedo"

  zap trash: [
    "~/Library/Application Support/Quedo",
    "~/Library/Application Support/quedo",
  ]
end
EOF

echo "Updated $TAP_DIR/Casks/quedo.rb for version $VERSION"
