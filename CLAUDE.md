# CLAUDE.md

## Git Workflow

Never commit directly to `main`. Always use feature branches, then merge locally and push. No PRs — this overrides the global CLAUDE.md PR requirement.

## Build Commands

```bash
# Build for macOS
xcodebuild -project Indite.xcodeproj -scheme Indite -destination 'platform=macOS' build

# Clean build
xcodebuild clean -project Indite.xcodeproj -scheme Indite
```

## Constraints

- **Minimum targets**: macOS 27 (iOS 26 for the iOS target, which is not in use) — use only APIs available on these platforms
- **Offline by default**: All processing (transcription, AI, diarization) is on-device. The network is reached only for Apple's speech model, the speaker models when the user installs them, and Sparkle's update check against the latest GitHub release
- **Privacy first**: Never send user data to external servers
