# Changelog

## [0.3.0](https://github.com/allapcallapc/LaPlanif/compare/v0.2.0...v0.3.0) (2026-08-30)


### Features

* add a button to extract the week's ingredient list ([#21](https://github.com/allapcallapc/LaPlanif/issues/21)) ([65085ae](https://github.com/allapcallapc/LaPlanif/commit/65085ae7e9fcfe698197598e5179c1067036e62d))
* add a structure review step before generating the meal plan preview ([bc04bf9](https://github.com/allapcallapc/LaPlanif/commit/bc04bf91f37fd12902f123360b38917011dbfd8f))
* add grocery flyer scraper for configurable stores ([#3](https://github.com/allapcallapc/LaPlanif/issues/3)) ([135dcc5](https://github.com/allapcallapc/LaPlanif/commit/135dcc533ae9c323bb84480fa4d24c6f7e500a75))
* add LaPlanif app icon ([#25](https://github.com/allapcallapc/LaPlanif/issues/25)) ([d3f5e24](https://github.com/allapcallapc/LaPlanif/commit/d3f5e242fd3f64ff9a2a0817d9271624476862fc))
* add manually-saved recipe history with diversity-window hint ([#14](https://github.com/allapcallapc/LaPlanif/issues/14)) ([7b2bb47](https://github.com/allapcallapc/LaPlanif/commit/7b2bb4756bb77c850e7f7bd872e6b3e11f00b158))
* add meal plan config data model and screen section ([#6](https://github.com/allapcallapc/LaPlanif/issues/6)) ([41a0348](https://github.com/allapcallapc/LaPlanif/commit/41a034800c02ce5c35f5e5090c7b65c3c803148b))
* add meal plan preview step between item preferences and recipe generation ([#7](https://github.com/allapcallapc/LaPlanif/issues/7)) ([b4cfc7c](https://github.com/allapcallapc/LaPlanif/commit/b4cfc7cae34c7fcbfda127dc005c588af98f66cf))
* add per-item deal preferences before meal-plan generation ([d84325c](https://github.com/allapcallapc/LaPlanif/commit/d84325c3fcbed11004ecb1b2060a6f0f679f669f))
* add per-recipe regenerate button to the full meal plan ([8f9e299](https://github.com/allapcallapc/LaPlanif/commit/8f9e299f9a1bd10ab588c651152d9cde4f5f8cba))
* add standing dietary planning instructions ([ddec042](https://github.com/allapcallapc/LaPlanif/commit/ddec04235e743390f9f8c09681082abe7e865fee))
* allow editing a recipe link when modifying a saved history entry ([d8836eb](https://github.com/allapcallapc/LaPlanif/commit/d8836eb10e9c6446ec946ba306ef3cce9a9f63ef))
* autosave in-progress meal plan draft to survive crash/refresh ([d8ef947](https://github.com/allapcallapc/LaPlanif/commit/d8ef9471173a4d0841041f185a767babe7e284bd))
* cache fetched deals and reset selections on reload ([f55504e](https://github.com/allapcallapc/LaPlanif/commit/f55504e40bde134c7e0aff21b0255d4a2386cb77))
* cache fetched deals and reset selections on reload ([6a3eaf7](https://github.com/allapcallapc/LaPlanif/commit/6a3eaf7cc28aad328849c40e542a84f72b5cd96d))
* generate full meals from confirmed preview slots ([dc68625](https://github.com/allapcallapc/LaPlanif/commit/dc6862584d34a5387e28c256cef5567582e8478b))
* merge preview and full-plan into one per-meal review step ([#27](https://github.com/allapcallapc/LaPlanif/issues/27)) ([35c454f](https://github.com/allapcallapc/LaPlanif/commit/35c454f8fe2668a6ebd41d39f10d744006c9cc3a))
* rebuild Planif's navigation as real pushed screens with a Home resume/start-over choice ([#42](https://github.com/allapcallapc/LaPlanif/issues/42)) ([38b4fe2](https://github.com/allapcallapc/LaPlanif/commit/38b4fe23783ec3dea0a28fa8b848f9d3bfec7eb4))
* redesign the Planif screen header and navigation ([8f1a8d9](https://github.com/allapcallapc/LaPlanif/commit/8f1a8d9de9ce8322bdf61bbae56fa584a14b24d0))
* show raw scraped page sample in AI Usage log ([#17](https://github.com/allapcallapc/LaPlanif/issues/17)) ([bf9da98](https://github.com/allapcallapc/LaPlanif/commit/bf9da9807065aaa44ce5405ba2526683e1863ab2))
* show which AI phase is running while generating a recipe ([#29](https://github.com/allapcallapc/LaPlanif/issues/29)) ([f7b559e](https://github.com/allapcallapc/LaPlanif/commit/f7b559e34132c7f28a4cbedcbd05673aef3f2b0f))
* split Config screen into drill-down sub-screens ([54bae90](https://github.com/allapcallapc/LaPlanif/commit/54bae90e97c9799f7061ef557dbb8a397d60607c))
* surface fetched-at timestamp and stale-flyer warning on deals ([#41](https://github.com/allapcallapc/LaPlanif/issues/41)) ([1f68b6b](https://github.com/allapcallapc/LaPlanif/commit/1f68b6b12a62768d54a34b47584b0f3a4a04c5bf))
* switch app theme to Berry color scheme ([#28](https://github.com/allapcallapc/LaPlanif/issues/28)) ([7897fec](https://github.com/allapcallapc/LaPlanif/commit/7897fecf8f5e2ffe08dca4ccdddac70eb682b16f))


### Bug Fixes

* exclude video links from grounded full-recipe search ([#15](https://github.com/allapcallapc/LaPlanif/issues/15)) ([02fb0d0](https://github.com/allapcallapc/LaPlanif/commit/02fb0d0a8faeb4ad91973e148964db20e41e783f))
* exclude YouTube, Facebook, and Reddit links from recipe search ([#24](https://github.com/allapcallapc/LaPlanif/issues/24)) ([66caf68](https://github.com/allapcallapc/LaPlanif/commit/66caf68f5512a81c706f3efe992302eb434c0dbb))
* harden AI-vs-link recipe preference to reduce unnecessary ai_recipe fallback ([#18](https://github.com/allapcallapc/LaPlanif/issues/18)) ([647a23d](https://github.com/allapcallapc/LaPlanif/commit/647a23d48db27118650d318a675b0fe8666c0361))
* harden planif cache/preference handling around fetch and reload ([ec039c1](https://github.com/allapcallapc/LaPlanif/commit/ec039c1a00b26523f74fd440ecb6a768b0b52b49))
* History empty-state padding, broken arrow glyph, and unconfirmed deletes ([1cce915](https://github.com/allapcallapc/LaPlanif/commit/1cce91592e7e64711573ee6059bc62165be7a17f))
* make recipe links clickable in the History detail screen ([#22](https://github.com/allapcallapc/LaPlanif/issues/22)) ([79333c2](https://github.com/allapcallapc/LaPlanif/commit/79333c2f2d33ec1b9b0ad64f8b837bc928c4b62b))
* show amber indicator when a retailer has 0 deals ([#20](https://github.com/allapcallapc/LaPlanif/issues/20)) ([557fc87](https://github.com/allapcallapc/LaPlanif/commit/557fc87ffb843a9d616588d6bd0b56d909cdcc4e))
* show grounding search result title instead of raw redirect link ([#23](https://github.com/allapcallapc/LaPlanif/issues/23)) ([48700db](https://github.com/allapcallapc/LaPlanif/commit/48700dbbaca6fa685c20b1a247ac38358d2404ec))
* stop a deal-item ingredient from bleeding onto its recipe-mates ([9738e5b](https://github.com/allapcallapc/LaPlanif/commit/9738e5b7b6e8decb7b73957eef58015e800e0a49))
* stop hallucinated recipe links from reaching the meal plan ([#12](https://github.com/allapcallapc/LaPlanif/issues/12)) ([949e719](https://github.com/allapcallapc/LaPlanif/commit/949e719a9e5f29b7311cc46dd9543586f1553f2a))

## [0.2.0](https://github.com/allapcallapc/LaPlanif/compare/v0.1.0...v0.2.0) (2026-08-18)


### Features

* scaffold LaPlanif web app with SplitBalance's CI/CD setup ([f43b654](https://github.com/allapcallapc/LaPlanif/commit/f43b6543b35d4d0638ef6a75b199fe62dcfa3134))
