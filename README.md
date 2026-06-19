# Quedo

Voice-to-text tool powered by Groq's Whisper API. Press a hotkey, speak, and get instant transcription.

## Get Started

Requires macOS and [uv](https://github.com/astral-sh/uv).

```bash
uv tool install quedo --from git+https://github.com/Futhark-AS/quedo.git
quedo --version  # shows how to upgrade
quedo init
```

The `init` wizard will:
1. Ask for your [Groq API key](https://console.groq.com/keys) (free)
2. Configure hotkeys and preferences
3. Start the background daemon

> **Note:** macOS Accessibility permissions are required for global hotkeys. Grant access in System Settings → Privacy & Security → Accessibility when prompted.

**Where files are stored** ([XDG Base Directory Specification](https://xdgbasedirectoryspecification.com/)):
| Path | Contents |
|------|----------|
| `~/.config/quedo/config.env` | API key, hotkeys, preferences |
| `~/.local/share/quedo/history/` | Audio recordings & transcriptions |
| `~/.local/state/quedo/logs/` | Log files |
| `~/.local/state/quedo/daemon.pid` | Daemon process ID |

## Usage

```bash
# Daemon control
quedo start
quedo stop
quedo restart
quedo status

# View logs
quedo logs
quedo logs --stderr

# Configuration
quedo config show
quedo config edit

# History
quedo history list
quedo history play 1      # play most recent recording
quedo history transcribe 1  # re-transcribe most recent

# Transcribe any audio file
quedo transcribe /path/to/audio.wav
```

## macOS App Downloads (GitHub Releases)

For friends who want a direct app download:

1. Open GitHub Releases and download `Quedo.dmg` (or `Quedo.app.zip`).
2. Move `Quedo.app` to `/Applications`.
3. Launch app and grant requested permissions.

Release publishing is automated:

- Push a tag like `v1.2.3`
- GitHub Actions builds and uploads:
  - `Quedo.dmg`
  - `Quedo.app.zip`
  - `quedo-cli-macos.zip`
  - `SHA256SUMS.txt`

Optional signing/notarization in CI is enabled when these repo secrets exist:
- `APPLE_CERTIFICATE_P12` (base64-encoded Developer ID Application `.p12`)
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY` (optional; auto-resolved if omitted)
- `APPLE_KEYCHAIN_PASSWORD` (optional)
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

### whisper.cpp Bootstrap (macOS app provider)

To use the local `whisper.cpp` provider in the macOS app:

```bash
./macos/scripts/bootstrap-whisper-cpp.sh
```

Then set `Preferences -> Providers -> whisper.cpp model` to the printed model path.

### Azure Speech / MAI-Transcribe (macOS app provider)

The macOS app can use Microsoft Azure Speech LLM Speech models, including `mai-transcribe-1.5`.
In `Preferences -> Provider Setup`, set:

- Azure Speech endpoint, for example `https://<resource>.cognitiveservices.azure.com`
- Azure Speech model, default `mai-transcribe-1.5`
- Azure Speech API key

The shared config keys are `AZURE_SPEECH_ENDPOINT`, `AZURE_SPEECH_MODEL`, and `AZURE_SPEECH_KEY`.

### OpenRouter transcription provider

The macOS app can also use OpenRouter's generic speech-to-text endpoint with any OpenRouter transcription model slug.
In `Preferences -> Provider Setup`, set:

- OpenRouter model, for example `microsoft/mai-transcribe-1.5`
- OpenRouter API key

The shared config keys are `OPENROUTER_MODEL` and `OPENROUTER_API_KEY`.

## Install with Homebrew (macOS app)

```bash
brew tap Futhark-AS/tap
brew install --cask quedo
```

Notes:
- Current cask targets Apple Silicon (`arm64`) and macOS 14+.
- Cask updates are automated from tagged releases when `HOMEBREW_TAP_GITHUB_TOKEN` is set in this repo's GitHub secrets.
- Tap repo expected by CI: `Futhark-AS/homebrew-tap`.

**Default hotkeys:**
- `Ctrl+Shift+1` — Toggle recording (press to start, press again to stop and transcribe)
- `Ctrl+Shift+2` — Retry last transcription
- `Ctrl+Shift+3` — Cancel recording

**Config location:** `~/.config/quedo/config.env`

## About uv tools

This CLI is installed via `uv tool install`, which:
- Creates an isolated venv at `~/.local/share/uv/tools/quedo/`
- Symlinks the CLI to `~/.local/bin/` (should be in your PATH)

If you want to use a shorter name for running the CLI, you can symlink it:

```bash
ln -sf ~/.local/bin/quedo ~/.local/bin/whisp
```

**Why git instead of PyPI?**
- Faster iteration without publishing releases
- Always get the latest from `main`

**Trade-off:** No pinned versions — you always pull latest. For stability, pin to a commit:
```bash
uv tool install quedo --from git+https://github.com/Futhark-AS/quedo.git@<commit-sha>
```

**Useful commands:**
```bash
uv tool list       # see installed tools
uv tool uninstall quedo
```

## Contributing

PRs welcome. For major changes, open an issue first.

```bash
git clone https://github.com/Futhark-AS/quedo.git
cd quedo
uv sync
uv run quedo --help
```

[MIT License](LICENSE)
