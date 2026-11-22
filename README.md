# LaPlanif

A Flutter web app that plans a week of meals around what's on sale at your grocery stores.

LaPlanif scrapes the weekly flyers for your stores (IGA, Metro, Maxi and Super C by default), uses Google's Gemini models to pull out the deals, and builds a meal plan with recipes and an aisle-grouped shopping list from them.

## Features

- **Planif**: fetch this week's deals, mark the items you want or want to skip, review the plan's structure, confirm the ingredients for every meal on one page (each meal always gets a carb, from the deals or a pantry staple like rice, quinoa or couscous), then generate the recipes (one at a time or all at once). A recipe always keeps the ingredients you confirmed, and can add another item from the deals when it uses one. You can regenerate a single recipe and pull out the week's full ingredient list. Your in-progress plan is saved automatically, so a refresh or crash doesn't lose it.
- **History**: keep the meal plans you save and edit their recipe links. Recently saved meals are passed to the generator so it doesn't suggest them again too soon.
- **Config**: set the stores and flyer URLs, your Gemini API key and the order models are tried in, and the default meal plan (meal slots, portions, how many days before a meal can repeat, and standing dietary instructions). An AI Usage log shows each AI call.

All data, including your API key, is stored in your browser's local storage. Nothing is sent anywhere except the flyer sites and the Gemini API.

## Getting started

You need your own Google AI (Gemini) API key. There is no default key: enter yours under **Config → AI** before fetching deals.

## Development

Requires the Flutter SDK (stable channel, Dart `^3.13.0`).

```
flutter pub get
flutter run -d web-server --web-port 8080
```

Run the tests and analyzer, as CI does:

```
flutter test
flutter analyze --no-fatal-infos
```

The app only targets the web for now; there is no Android or iOS build.

## Releases

Releases are automated by [release-please](https://github.com/googleapis/release-please-action). Merging a PR titled with a Conventional Commit prefix (`feat:`, `fix:`, ...) updates a running "Release PR". Merging that PR cuts a release and deploys the web build to GitHub Pages. See `CLAUDE.md` for details and [`CHANGELOG.md`](CHANGELOG.md) for release history.

## Deploy previews

- Production (latest release): https://allapcallapc.github.io/LaPlanif/
- `main` branch: https://allapcallapc.github.io/LaPlanif/main/
- Each open PR gets its own preview at `/pr-<number>/`, linked from the PR's checks.
