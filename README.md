# LaPlanif

A Flutter web app (currently a single "under construction" screen).

## Development

```
flutter pub get
flutter run -d web-server --web-port 8080
```

## Releases

Releases are automated by [release-please](https://github.com/googleapis/release-please-action): merging a PR titled with a Conventional Commit prefix (`feat:`, `fix:`, ...) updates a running "Release PR"; merging that PR cuts a release and deploys the web build to GitHub Pages. See `CLAUDE.md` for details.

## Deploy previews

- `main` branch: https://allapcallapc.github.io/LaPlanif/main/
- Each open PR gets its own preview at `/pr-<number>/`, linked from the PR's checks.
- Production (latest release): https://allapcallapc.github.io/LaPlanif/
