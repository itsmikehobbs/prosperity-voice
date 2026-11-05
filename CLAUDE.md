# Prosperity Voice — notes for AI agents

- Given this repo's link, or asked to install, update, or uninstall Prosperity Voice? Follow
  [INSTALL.md](INSTALL.md) step by step for the user's computer.
- Working on the code: the Mac app is Swift in `Sources/` (build with `scripts/build.sh`); the
  Windows app is C# .NET 9 in `windows/` (build with `dotnet build windows/ProsperityVoice.csproj`).
  Both have self-tests (`--selftest --fast`). The Android app is Kotlin in `android/` (see `docs/notes.md`). Design notes: `docs/notes.md`.
