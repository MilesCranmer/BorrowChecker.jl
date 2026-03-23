# Changelog

## [0.4.5](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.4...v0.4.5) (2026-03-23)


### Bug Fixes

* handle missing LineNumberNode file/line ([#58](https://github.com/MilesCranmer/BorrowChecker.jl/issues/58)) ([855c156](https://github.com/MilesCranmer/BorrowChecker.jl/commit/855c1562ce7af4e1e1660ee81bbeb7912333833d))

## [0.4.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.3...v0.4.4) (2026-01-26)


### Bug Fixes

* issue [#49](https://github.com/MilesCranmer/BorrowChecker.jl/issues/49) ([0e8bbeb](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0e8bbebdc993c4a909478027bdcb59ac82506ee6))
* issue [#49](https://github.com/MilesCranmer/BorrowChecker.jl/issues/49) ([9ae3e90](https://github.com/MilesCranmer/BorrowChecker.jl/commit/9ae3e90017be72e1a7ef6531f159c8cfe28578c9))

## [0.4.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.2...v0.4.3) (2026-01-25)


### Bug Fixes

* much cleaner treatment of unsafe ([5f7234c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5f7234c4499ee6e91298a1bbe518d9850f59572d))
* poorly masked unsafe blocks ([4234dec](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4234decb679c5f38f91be33f12c85ddbb511e913))
* poorly masked unsafe blocks ([0240a1c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0240a1cabe6bd038357ca901dd0962c8c4880af3))
* safer bindings ([eedddfa](https://github.com/MilesCranmer/BorrowChecker.jl/commit/eedddfa66809e1de951d47b84069c46b82c0ef3d))

## [0.4.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.1...v0.4.2) (2026-01-24)


### Features

* create `[@unsafe](https://github.com/unsafe)` macro and matching `[@safe](https://github.com/safe)` macro ([cea4efb](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cea4efb58f2d27b609e8ee8dc96355c50c48c311))
* rename other `[@auto](https://github.com/auto)` to `[@safe](https://github.com/safe)` ([244137f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/244137f332aee20b36a563aba8f3cd9eb3bc7aa6))


### Bug Fixes

* unsafe operation for semicolons ([10e5303](https://github.com/MilesCranmer/BorrowChecker.jl/commit/10e5303a3d626b3bf8de694fd67cd962f9d31999))

## [0.4.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.0...v0.4.1) (2026-01-20)


### Features

* create debug system ([49ab087](https://github.com/MilesCranmer/BorrowChecker.jl/commit/49ab087c1e6f1460fc521ca78abf26201a382901))


### Bug Fixes

* additional edge cases ([cbc1de6](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cbc1de60287dacf71143a70438e1a50afa1ad1a6))
* additional edge cases ([ceab23f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/ceab23f16ef66e636c84a6f9ab15c058592e6ef2))
* eliminate assumptions about Base methods ([a62ff44](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a62ff44e77981f5df66b64bb5be086f646594fab))
* ignore `Core` for `:user` scope ([e217d69](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e217d69abe0dfeea5a0418f919daf36fcc030fad))
* ignore `Core` for `:user` scope ([a4c2b06](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a4c2b067c27ec0513d9e390d01fab5493ea6a33e))
* JET identified error ([3811b9a](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3811b9a798f5acf7598ec8e5cd211fd8f6cf97b8))
* more failure cases ([5d45ee2](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5d45ee24d3a55add1db2d963599951c7ff5b4a15))
* special-case Tasks ([adac867](https://github.com/MilesCranmer/BorrowChecker.jl/commit/adac867539b8edc6f945c73827724bb00619349c))
* special-case Tasks ([a2d656f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a2d656f64daefaf45c7bee5a17329db94b719f31))
* work around a variety of edge cases ([c96ef7a](https://github.com/MilesCranmer/BorrowChecker.jl/commit/c96ef7aa4ed1e04d16be76364f38bf3d64bfce24))

## [0.4.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.3.1...v0.4.0) (2026-01-16)


### Features

* better handling of foreigncall ([e457204](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e457204f2f86b981062978406d2a39e952c53156))
* handle a subset of foreigncall effects ([5852b81](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5852b818e7200e517d9ec2e58d0f9626dd4fc6f1))
* handle a subset of foreigncall effects ([cd467c2](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cd467c229edc560c0b3f21e5414f0ef462da23e0))
* permit recursive borrow checking ([4878584](https://github.com/MilesCranmer/BorrowChecker.jl/commit/48785847b64a004656d482025e0084cfd8b2098a))


### Bug Fixes

* add missing `Core.isa` ([4126463](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4126463e192699942ecc175a39368e4bccd19b6c))
* add missing BoundsError ([1ab5ca5](https://github.com/MilesCranmer/BorrowChecker.jl/commit/1ab5ca5dd069df4b8a340eea6104dd505799a860))
* behavior for module scoping and add test ([dc2b5a3](https://github.com/MilesCranmer/BorrowChecker.jl/commit/dc2b5a3c3c7a28cbf056eaf6cd07e6e04b4f615a))
* handle PhiCNode ([9e9aa4e](https://github.com/MilesCranmer/BorrowChecker.jl/commit/9e9aa4ec6d9afacd2cb56c47eaf492fd90e2600f))
* incorrect return from generated ([89008fd](https://github.com/MilesCranmer/BorrowChecker.jl/commit/89008fd2848826dd8b0b31de98a78249edb70ec5))
* optimization pass normalization ([5c86b33](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5c86b337820246047a7fde627962ce3c7e3c4b9f))
* register Typeof ([7715a5c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/7715a5cabe93ab754f11e9159064dfeface82174))

## [0.3.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.3.0...v0.3.1) (2026-01-14)


### Features

* add simple tracking for Ptr objects ([4fb8391](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4fb839132dfc011ca9e6618d2c43e5480acd730c))
* handle pointers better ([b2fa53b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b2fa53b000aeff58b481b52f05a8eb1b9af74d1d))
* much faster caching ([71b7e96](https://github.com/MilesCranmer/BorrowChecker.jl/commit/71b7e96d4064f06c755001b54c6c386e4ac9704c))


### Bug Fixes

* returning duplicate tuples ([a9d7955](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a9d795517887ee6d7cffd76204616194fc3ff4b4))

## [0.3.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.2.1...v0.3.0) (2026-01-14)


### Features

* better debug info ([e50152a](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e50152a62135f3bf57e7d04bc00431322229144a))
* cover additional cases ([0d30050](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0d300506518e760237d6e69ba756701dd202a376))
* create IR borrowchecker ([90d5ea2](https://github.com/MilesCranmer/BorrowChecker.jl/commit/90d5ea21fcc8f37137198c4d4467e70366456b08))
* detecting borrow check violations recursively ([d0bd6af](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d0bd6af1dce3f2e1cc5d3ff53a06bc8f3ce1438a))
* greatly accelerate analysis with local cache ([d421da0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d421da0ba1f8ac2868add3b356b5b904357443db))
* handle file changes ([b1a5cb1](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b1a5cb15d303a357585c1010c0ebe8c820fc424b))
* handle more edgecases ([96bfdfd](https://github.com/MilesCranmer/BorrowChecker.jl/commit/96bfdfdc0acf56c9b159cef623135e8c527fe7c5))
* more general version of kwcall ([9574332](https://github.com/MilesCranmer/BorrowChecker.jl/commit/9574332f50cb012fafe5097dc3255d3481441f7d))
* no need for wrapping blocks ([d90fc7c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d90fc7ccbd9b663f8d6760158f463dd7e1755294))
* some closure compatibility ([1893534](https://github.com/MilesCranmer/BorrowChecker.jl/commit/18935348d5d36ccc15fb3e1baec1cc992c50b421))
* track consumed values better ([3c928fb](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3c928fb2683c657e3cfa52dba80151eb8167eda4))
* try to improve printing ([832f656](https://github.com/MilesCranmer/BorrowChecker.jl/commit/832f656179c7fa244680058bad8aac92aa6bdb0e))


### Bug Fixes

* aliasing through kwcall ([6075967](https://github.com/MilesCranmer/BorrowChecker.jl/commit/607596786257a0adb4960f6e6d91e18aa4e95b33))
* behavior for nested closures ([0b6a3dc](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0b6a3dc1955eb24a9b3d9a3bb403bce92df9ecbe))
* behavior for some Ptr operations ([74e2ac0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/74e2ac076bb43f01f24a7cd406eb9359c77cb2b6))
* caching of files ([4377014](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4377014912939e78725f935b36a948162790b169))
* dont assume ! means anything ([549eee3](https://github.com/MilesCranmer/BorrowChecker.jl/commit/549eee3caca93e89989c3a382f3c439ce5913e19))
* foreigncall bug ([1c2637e](https://github.com/MilesCranmer/BorrowChecker.jl/commit/1c2637e4e98bc80461b6c440c43e922292387773))
* handle some kw alias detection ([d455ac5](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d455ac5f6162a5f7d47bce96d0bd639d8d5d5649))
* inference barrier effects ([42f33dc](https://github.com/MilesCranmer/BorrowChecker.jl/commit/42f33dc7216bd4cf6ae5a07a49616272ce50bab1))
* non-determinism of caching limit based on depth ([6b23311](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6b23311d143cce7c3a9234457133c6cd384c17d7))
* only define core IR methods ([cb9a308](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cb9a308fd2aced343bb3ee3dd38d7a04f28da24a))
* only enable automatic checks on valid julia ([741054e](https://github.com/MilesCranmer/BorrowChecker.jl/commit/741054e52f06887786ba3f7a59860c6a27f8a133))
* prevent cache cycles ([50d4629](https://github.com/MilesCranmer/BorrowChecker.jl/commit/50d4629fd6f91e256800a8bbf2fd76cc08286c60))
* printing on nightly ([d5983e1](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d5983e13b636df74a8584812484e64fdd22f2067))
* repl printing ([74b2737](https://github.com/MilesCranmer/BorrowChecker.jl/commit/74b2737eb75c8c7c1ebdb00ccfd8525bc2c4c7af))
* some printing issues in ir ([e3b9cff](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e3b9cff90828b541e776f9af2cf71b0feec0ac08))
* use compact 1 on 1.12 ([56cdcdf](https://github.com/MilesCranmer/BorrowChecker.jl/commit/56cdcdff9a7b779dab53a6efaa95905690bd1f32))

## [0.2.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.2.0...v0.2.1) (2025-04-27)


### Features

* add additional numerics overloads ([b8a6607](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b8a66077e5ecdda093f390cb16e52e8364538f00))


### Bug Fixes

* nested property writes in LazyAccessor ([f0787ec](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f0787ec31dc3c95072bb1de889fc64f3cf9e0ef4))

## [0.2.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.5...v0.2.0) (2025-04-27)


### ⚠ BREAKING CHANGES

* make `@bc` default to immutable

### Features

* allow immutable borrow of mutable borrow ([009986d](https://github.com/MilesCranmer/BorrowChecker.jl/commit/009986df16767afcbd75b7e7435f5f4b19af2b50))
* allow immutable borrow of mutable borrow ([5b5f63c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5b5f63c07aaa84e53f9b671dff15614f493dd759))
* make `[@bc](https://github.com/bc)` default to immutable ([b88c107](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b88c107be8ab0bd8895464e7969e3081bdbbe837))


### Bug Fixes

* forwarding of `randn` ([c9ed13a](https://github.com/MilesCranmer/BorrowChecker.jl/commit/c9ed13a628c9750969893eaabe58126d15e237a9))
* forwarding of `randn` ([fb2eb29](https://github.com/MilesCranmer/BorrowChecker.jl/commit/fb2eb294931821f5c1d959c8303e58b58d9bc278))

## [0.1.5](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.4...v0.1.5) (2025-04-26)


### Bug Fixes

* `@&` when wrapping type parameters ([fbdd908](https://github.com/MilesCranmer/BorrowChecker.jl/commit/fbdd908adea2c7b0e4441fa15e88cb0933488c8e))
* `@&` when wrapping type parameters ([ebc1c60](https://github.com/MilesCranmer/BorrowChecker.jl/commit/ebc1c607295ac0ef36a56f089f842dc5a40cdc30))

## [0.1.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.3...v0.1.4) (2025-04-25)


### Features

* add basic broadcasting compatibility ([1a16166](https://github.com/MilesCranmer/BorrowChecker.jl/commit/1a1616600c15eebe9c3c7d6d62ac60db99761050))
* add basic broadcasting compatibility ([d8c15c5](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d8c15c5db7038207505e97183d8b09468a0d6d77))
* block wrapper objects from being captured ([4ba37e6](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4ba37e60c53ceaf41e1a4f3470c408ec96a23011))
* create `@&` macro for borrowed types ([f6cc68d](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f6cc68dd0cd176d52574257593a9be9271ac016b))
* create `Mutex` object for safe mutable references ([0681a74](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0681a749b6bbf51933ce6c351ab77323edf698f2))
* create new `@&` shorthand ([4eac033](https://github.com/MilesCranmer/BorrowChecker.jl/commit/4eac03364cbeb415d1852dbd3ab5de7d229d577b))
* more locking API ([69795d8](https://github.com/MilesCranmer/BorrowChecker.jl/commit/69795d85aa9bb679a0e5960b56f5255361d3b8b5))
* more overloads of types ([f615bde](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f615bde2c80bf04176ef51a5904826026ab1503c))
* more streamlined mutex interface ([bd02443](https://github.com/MilesCranmer/BorrowChecker.jl/commit/bd02443a431bddb080b54f759db2118a1fd8a9dd))

## [0.1.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.2...v0.1.3) (2025-04-13)


### Features

* create `[@spawn](https://github.com/spawn)` macro for wrapped `Threads.[@spawn](https://github.com/spawn)` ([2857f83](https://github.com/MilesCranmer/BorrowChecker.jl/commit/2857f833d967506ddba980ea78919621d533eb38))
* draft `[@cc](https://github.com/cc)` macro for checking closures ([7e1d4a1](https://github.com/MilesCranmer/BorrowChecker.jl/commit/7e1d4a1688101b27a59cdd018b9eb49308376dd6))
* overload `reshape` ([29d9bf4](https://github.com/MilesCranmer/BorrowChecker.jl/commit/29d9bf4d1af470fab2e4a0de70ec3854b7cf3b2c))
* overload `reshape` ([da394ef](https://github.com/MilesCranmer/BorrowChecker.jl/commit/da394efa62c76f36530f886f7ed3e77cdddfe134))


### Bug Fixes

* avoid expression parsing, use dynamic approach ([2253208](https://github.com/MilesCranmer/BorrowChecker.jl/commit/225320836dac93ffddd8d0d8be4706ef485f2a8f))

## [0.1.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.1...v0.1.2) (2025-04-12)


### Features

* overload `adjoint` and `transpose` ([0c1e912](https://github.com/MilesCranmer/BorrowChecker.jl/commit/0c1e9120d49c277be462261d26a4569bdc00fb50))
* overload `adjoint` and `transpose` ([91bf818](https://github.com/MilesCranmer/BorrowChecker.jl/commit/91bf8183367ad51a76e84b58ca8b901cd0b5fd7d))

## [0.1.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.0...v0.1.1) (2025-04-11)


### Features

* more collection overloads ([11820f0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/11820f06a4476313c48780cf26ca8f672b31eae7))

## [0.1.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.13...v0.1.0) (2025-04-10)


### Features

* add `shuffle!(rng, ...)` overload ([22dc377](https://github.com/MilesCranmer/BorrowChecker.jl/commit/22dc3771c1c16208b43fa574cad34ee3434be9b7))
* more overloads ([d2a4294](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d2a42946b4dc5dbdaeb48e70f399ac3011effa2d))

## [0.0.13](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.12...v0.0.13) (2025-04-09)


### Features

* add `isless` to operators ([30cb625](https://github.com/MilesCranmer/BorrowChecker.jl/commit/30cb625e6c7baa61cb8916ba9d18197175da0fb6))
* add `shuffle!` overload ([f409a6c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f409a6cadffa08696679d757be148c1bb80e2413))
* have `[@bc](https://github.com/bc)` pass through static values ([573e089](https://github.com/MilesCranmer/BorrowChecker.jl/commit/573e08905932aec215a3fea69628cd9dc2ebbccb))
* make `[@bc](https://github.com/bc)` work for shorthand kwargs ([90967c2](https://github.com/MilesCranmer/BorrowChecker.jl/commit/90967c246531aa5ec4a064646a9e67def37a0263))

## [0.0.12](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.11...v0.0.12) (2025-04-08)


### ⚠ BREAKING CHANGES

* remove experimental managed feature

### Features

* add safe `Base.copy` ([a03ed93](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a03ed93d92fb1fec88a166e1fdd6e6684b9a2640))
* better error messages ([d13679b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d13679b29750a36a59afb04cf43014a24ac8320b))
* better errors for mixed tuples in ref ([20cafc8](https://github.com/MilesCranmer/BorrowChecker.jl/commit/20cafc8b5e511c1fe8538499815a55ed4b79c2df))
* more operators for Number ([acc5829](https://github.com/MilesCranmer/BorrowChecker.jl/commit/acc5829cdf6033ba14ee9630f83ed07c16469ae8))
* remove experimental managed feature ([86832d9](https://github.com/MilesCranmer/BorrowChecker.jl/commit/86832d9e65a92aa441c930f535c2fabc411d3afe))


### Bug Fixes

* ensure deepcopy inside `copy!` ([3b8ad27](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3b8ad2710eca5652e2a77eef42fd1ae53073b3e5))
* some ambiguities ([50fbd22](https://github.com/MilesCranmer/BorrowChecker.jl/commit/50fbd223d86647fccc8924c0e4553758a9e2be0e))

## [0.0.11](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.10...v0.0.11) (2025-01-20)


### ⚠ BREAKING CHANGES

* remove `@set` syntax

### Features

* remove `[@set](https://github.com/set)` syntax ([59f9b81](https://github.com/MilesCranmer/BorrowChecker.jl/commit/59f9b810804f3160add7bf0e27bd89adba73c85e))

## [0.0.10](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.9...v0.0.10) (2025-01-20)


### Features

* add `Module` to `is_static = true` category ([a71ea45](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a71ea4550ff58f72fc8e8f7651ae8d9a37c6de1e))
* allow `[@own](https://github.com/own)` on nested for loops ([b0c1412](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b0c1412846e441fefeecccfe2cc03fd3459d8806))
* make String is_static ([aac4c5d](https://github.com/MilesCranmer/BorrowChecker.jl/commit/aac4c5d903eb08317bf7d086ce63afc9804f8ca4)), closes [#4](https://github.com/MilesCranmer/BorrowChecker.jl/issues/4)


### Bug Fixes

* cache collision with default UUID ([8bc21d6](https://github.com/MilesCranmer/BorrowChecker.jl/commit/8bc21d6f496bca20191178fe6cb5d43eb50abfaa))

## [0.0.9](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.8...v0.0.9) (2025-01-19)


### Features

* allow tuple assignment for `[@ref](https://github.com/ref)` ([3e7f0fb](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3e7f0fb3414ea89482ecf9c7865afb4248ea9f26))
* enable single-arg `[@own](https://github.com/own) x` macro ([6f7ae59](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6f7ae592220625e51d43a7b38721ce77e6c35bd2))
* more overloads ([405746f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/405746f7e3592a178926700d0724e172566b1a71))

## [0.0.8](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.7...v0.0.8) (2025-01-18)


### ⚠ BREAKING CHANGES

* change `disable_borrow_checker!` to `disable_by_default!`

### Features

* change `disable_borrow_checker!` to `disable_by_default!` ([b2062e5](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b2062e5aab55410154fd3efdcede351d4fc60a54))

## [0.0.7](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.6...v0.0.7) (2025-01-18)


### ⚠ BREAKING CHANGES

* remove unneccessary promote_rule
* mark moved through lazy access in `@managed` context
* `@managed` maps keywords
* get `empty!` and `resize!` to not return vector
* more `nothing` returns
* change `@ref` syntax to use `~lt` instead of `lt`
* fix incorrect version increment

### deps

* fix incorrect version increment ([b9024eb](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b9024eb54dde0e17ed15bc6abc68c845e3161406))


### Features

* `[@managed](https://github.com/managed)` maps keywords ([f97d437](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f97d437ca2e72bd22423d8b63b8f1f7ff89f08fa))
* change `[@ref](https://github.com/ref)` syntax to use `~lt` instead of `lt` ([5a6a011](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5a6a011a3206ee25a7fe60decb5e67f6ca085f74))
* correct `hash` definition ([5fbb747](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5fbb747117bd6e939b852968bbd307c75242b8fd))
* mark moved through lazy access in `[@managed](https://github.com/managed)` context ([479fb9b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/479fb9b4bf1d4f870b85517d531e2da8bef52243))
* prevent capturing lazy accessor of owned variables ([6de885f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6de885fd5e498a562c4da1b581fbb41f1bb78292))


### Bug Fixes

* get `empty!` and `resize!` to not return vector ([965e088](https://github.com/MilesCranmer/BorrowChecker.jl/commit/965e088adc9d42433b1231948346f7f04391fea1))
* improved error message mentioning `[@ref](https://github.com/ref)` ([3e8e43c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3e8e43c04a082722ff227a422421cbf0d6189c0c))
* more `nothing` returns ([080663b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/080663bae5e3a456082fc9ed062237d256ef8ea3))
* property set on owned ([2613eff](https://github.com/MilesCranmer/BorrowChecker.jl/commit/2613effcfc1e19b8a0e4798bd4edb577b1f308a2))
* remove unneccessary promote_rule ([2064f15](https://github.com/MilesCranmer/BorrowChecker.jl/commit/2064f15f7fd3ce5aa4379570eb94d9664884a3d5))

## [0.0.6](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.5...v0.0.6) (2025-01-16)


### ⚠ BREAKING CHANGES

* move `@managed` to experimental submodule
* rename bind to own

### Features

* rename bind to own ([cbe3bf6](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cbe3bf6e2f900396596363e7049f2e6e6a28fa0a))


### Code Refactoring

* move `[@managed](https://github.com/managed)` to experimental submodule ([256d5c0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/256d5c0d8288a9bf9f732b2d98f02946326f17ff))

## [0.0.5](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.4...v0.0.5) (2025-01-12)


### ⚠ BREAKING CHANGES

* dont validate symbols for borrowed values
* avoid deepcopy on static when turned off

### Features

* avoid deepcopy on static when turned off ([e9fefa4](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e9fefa4ad88ef8acd51e118a77f93e00255baed6))
* dont validate symbols for borrowed values ([094ddce](https://github.com/MilesCranmer/BorrowChecker.jl/commit/094ddce1dafa03d97543c41c71f51cec0d1cf85f))

## [0.0.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.3...v0.0.4) (2025-01-12)


### ⚠ BREAKING CHANGES

* expand definition of automatically copyable types

### Features

* add a couple fallback options ([85b2565](https://github.com/MilesCranmer/BorrowChecker.jl/commit/85b256575400d15134a38df27421b9cf58f1caac))
* add abstract types ([feebb7d](https://github.com/MilesCranmer/BorrowChecker.jl/commit/feebb7d89b50a79528452befa0f0a2fa4c57ca8a))
* expand definition of automatically copyable types ([42e2cce](https://github.com/MilesCranmer/BorrowChecker.jl/commit/42e2ccefee5370f197d4e114c2188ed9f1bf0c7d))
* extensions of LazyAccessorOf ([33eba5c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/33eba5cb9f026d3bf2e9d6d70e54117a3092f2b3))
* flag captured bound variables in closures ([9db33a1](https://github.com/MilesCranmer/BorrowChecker.jl/commit/9db33a121620e4dab2a9a04a913a5ce9c4a043be))
* various quality of life overloads ([cb73219](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cb732197bb2bd549b984c162d3d4f2c360dc5852))


### Bug Fixes

* view of LazyAccessor ([744ee47](https://github.com/MilesCranmer/BorrowChecker.jl/commit/744ee47a41881fc3b94306ee29d8df353cb8352e))

## [0.0.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.2...v0.0.3) (2025-01-12)


### ⚠ BREAKING CHANGES

* change syntax `@take` -> `@take!`
* create `LazyAccessor` to allow subproperty mutation

### Features

* allow `[@bind](https://github.com/bind)` used like `[@move](https://github.com/move)` ([cd3ea50](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cd3ea506e83ff25f9a70c898e844f473bbf147ab))
* allow `[@ref](https://github.com/ref)` for loops ([7779280](https://github.com/MilesCranmer/BorrowChecker.jl/commit/77792803a629414b95abee41ecc6639c5bf3530e))
* allow tuple unpacking for `[@bind](https://github.com/bind)` ([266c7db](https://github.com/MilesCranmer/BorrowChecker.jl/commit/266c7dbca61d9df422fb4b9dcb3eb4a6c097f41f))
* better errors for misuse ([7c5adde](https://github.com/MilesCranmer/BorrowChecker.jl/commit/7c5adde726b6cd75291f002fc71f7048f6601e6f))
* change syntax `[@take](https://github.com/take)` -&gt; `[@take](https://github.com/take)!` ([3740550](https://github.com/MilesCranmer/BorrowChecker.jl/commit/37405508eb23d1c2ec0325fc7d188e27c6d71b4d))
* create `LazyAccessor` to allow subproperty mutation ([496c287](https://github.com/MilesCranmer/BorrowChecker.jl/commit/496c2878daba94366ba35c828a251dc5dae9174d))
* ensure `deepcopy` still happens when turned off ([641f800](https://github.com/MilesCranmer/BorrowChecker.jl/commit/641f8009ae0bda5fef17eb34fe60de951297a942))
* helpful error for misuse of `bind` ([21e34c6](https://github.com/MilesCranmer/BorrowChecker.jl/commit/21e34c61981dea798af904018a3e473801dbeb35))
* iterator of mutable references ([ba09d5b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/ba09d5b0778ec1e6945fb540dad89a50013b1348))
* prevent borrowed object from being bound ([a583d34](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a583d3439103b826f59a85936e1358bbf0b20f31))
* printing for LazyAccessor ([7d70f18](https://github.com/MilesCranmer/BorrowChecker.jl/commit/7d70f18568f94c31a4efdbaa3f6a7fb3a8cbdb7c))


### Bug Fixes

* validate symbol missing anonymous ([a8d17c9](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a8d17c9dd3542baef00810fc71a62f5f9dc8bd11))

## [0.0.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.1...v0.0.2) (2025-01-10)


### ⚠ BREAKING CHANGES

* change syntax `@own const` -> `@bind`, `@own` -> `@bind @mut`
* change `Owned` -> `Bound`, `OwnedMut` -> `BoundMut`
* change `@bind @mut` to `@bind :mut`
* symbol tracking in more macros
* mutable collection functions return nothing
* make `managed` a macro
* different syntax for `@ref`

### Features

* `[@atomic](https://github.com/atomic)` operations for mutable, just in case ([1501798](https://github.com/MilesCranmer/BorrowChecker.jl/commit/1501798c865fd0fe0a017d4ca4898468edf6070e))
* `bind` for for loops ([47c7919](https://github.com/MilesCranmer/BorrowChecker.jl/commit/47c7919c074d9698e1dbd14c0b8aff645dccdb4b))
* add missing `eachindex` ([639351f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/639351fcedca7fd2faad4f053275725d1d10c796))
* add more overloads ([01511a3](https://github.com/MilesCranmer/BorrowChecker.jl/commit/01511a3c188228ac8cd6336593e1c7d932c1c1fa))
* allow `[@managed](https://github.com/managed)` to work with isbits ([e35e23c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/e35e23cafa53679762959866612a7835924306e9))
* allow disabling borrow checker ([6ae8a29](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6ae8a29e3d41c180925ba44983eda4f7210e4be6))
* automatically clone `isbits` ([9d919a8](https://github.com/MilesCranmer/BorrowChecker.jl/commit/9d919a8984b57c3530b50c88c8384c418de44d10))
* change `[@bind](https://github.com/bind) [@mut](https://github.com/mut)` to `[@bind](https://github.com/bind) :mut` ([15b3c70](https://github.com/MilesCranmer/BorrowChecker.jl/commit/15b3c7093acd29e829a5e8b8099d4eb8b80b7876))
* change `Owned` -&gt; `Bound`, `OwnedMut` -&gt; `BoundMut` ([18bb37c](https://github.com/MilesCranmer/BorrowChecker.jl/commit/18bb37c4fa4e872134f6964b2edd9565a1c44601))
* change syntax `[@own](https://github.com/own) const` -&gt; `[@bind](https://github.com/bind)`, `[@own](https://github.com/own)` -&gt; `[@bind](https://github.com/bind) [@mut](https://github.com/mut)` ([d111edd](https://github.com/MilesCranmer/BorrowChecker.jl/commit/d111edd8cadd0658737f1c1baabbaabbb0f0c7eb))
* create `[@clone](https://github.com/clone)` operator ([40301f0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/40301f0b424700661d141a88bdaae2d6d09b5911))
* create `managed()` context with Cassette.jl ([68d7aa9](https://github.com/MilesCranmer/BorrowChecker.jl/commit/68d7aa9e2c1f9596618e12d322fef5387d04aa6b))
* different syntax for `[@ref](https://github.com/ref)` ([31f1ef4](https://github.com/MilesCranmer/BorrowChecker.jl/commit/31f1ef40cfe1ed79e86d1e39d357d26fb6d0f24c))
* disable `managed` too ([def2317](https://github.com/MilesCranmer/BorrowChecker.jl/commit/def2317a5e377c7156bb1c87aabae04ba44b0498))
* feature to disable manually ([cc5f581](https://github.com/MilesCranmer/BorrowChecker.jl/commit/cc5f5813b48a23b97e4807a900cb5b0632c56709))
* iteration for `Borrowed` ([ee30237](https://github.com/MilesCranmer/BorrowChecker.jl/commit/ee302378e6fc1de36d605cbba97232c43fd956c3))
* make `managed` a macro ([db41870](https://github.com/MilesCranmer/BorrowChecker.jl/commit/db41870aa4768edbe59dd6c98b0ca923dcf7533a))
* mutable bindings in loop ([6cd0f92](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6cd0f9277e9f0165a51f6c7918abdf54708b0ccf))
* symbol tracking in more macros ([3d99c07](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3d99c07080c9414c135c6be01f2b98f65f98f53c))


### Bug Fixes

* additional uses of `isbits` ([9371368](https://github.com/MilesCranmer/BorrowChecker.jl/commit/937136853f88092f85ac7dba9f28e674be5e0520))
* additional uses of `isbits` ([349df2a](https://github.com/MilesCranmer/BorrowChecker.jl/commit/349df2aec816bfd1702714041931c9e12f8226c0))
* additional uses of `isbits` ([995824b](https://github.com/MilesCranmer/BorrowChecker.jl/commit/995824b124ec63d141e78c001ee1d8c57fd47db1))
* avoid using `threadid` which can change ([f2fa07d](https://github.com/MilesCranmer/BorrowChecker.jl/commit/f2fa07d557a4ab5ec5d460e6c5edf6579baa143c))
* bad signature for lifetime ([a7a2470](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a7a24705000809cdaf153d79ef282a74a8b036f0))
* better error ([b493532](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b493532046e9044f9f4bdae5e2ebc0bda9b223e6))
* check for moved in `managed()` ([7cf3a33](https://github.com/MilesCranmer/BorrowChecker.jl/commit/7cf3a33823146db11dad87e9826476f432acd231))
* iter for AllBound ([eb8c6b3](https://github.com/MilesCranmer/BorrowChecker.jl/commit/eb8c6b315d062096fb9e57d7b7d773a63ec5d391))
* managed borrows ([42cfd40](https://github.com/MilesCranmer/BorrowChecker.jl/commit/42cfd405272558f7558c5bac132ede2e6416f2b3))
* mutable collection functions return nothing ([2aff2f8](https://github.com/MilesCranmer/BorrowChecker.jl/commit/2aff2f8249825dc322add81a38aafcff0c15729c))
* old error message ([a4af972](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a4af972ddca93908b18a3e0d05f73a227cc30f33))
* test of `[@managed](https://github.com/managed)` ([196fe06](https://github.com/MilesCranmer/BorrowChecker.jl/commit/196fe069f2bcbc4416dbce80a74f429c99c47a0f))

## 0.0.1 (2025-01-10)


### ⚠ BREAKING CHANGES

* ban single-arg `@move`
* tweak `@ref` syntax
* replace `@own` -> `@own const`, `@own_mut` -> `@own`
* replace `@ref` -> `@ref const`, `@ref_mut` -> `@ref`
* change `@move` symantics to specify mutability

### Features

* add 2-arg `rem` ([60b7595](https://github.com/MilesCranmer/BorrowChecker.jl/commit/60b7595fdb71e48433478350a7a287dd25db129c))
* add basic math operations ([91c57f0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/91c57f0f1964ecb2cd4a9c04135a3fc3cc5b4cd7))
* allow references in threads ([c9bf188](https://github.com/MilesCranmer/BorrowChecker.jl/commit/c9bf188f8dddf9ad40a3bc3da0f6e0bee23177b5))
* ban single-arg `[@move](https://github.com/move)` ([c813362](https://github.com/MilesCranmer/BorrowChecker.jl/commit/c8133624e1844b0a72351f4ab3a6a751ba38658d))
* block mutable references in threads ([5d1450f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5d1450f63c2fbe054244d4359cf3f5c527e61693))
* change `[@move](https://github.com/move)` symantics to specify mutability ([24006b3](https://github.com/MilesCranmer/BorrowChecker.jl/commit/24006b31593501beea36ab296262e4aa318a33e7))
* implement more parts of array interface ([33ed363](https://github.com/MilesCranmer/BorrowChecker.jl/commit/33ed363cbf4c5b9d9bd571159a5461c4c9768681))
* init sync and send traits ([a21e4a1](https://github.com/MilesCranmer/BorrowChecker.jl/commit/a21e4a1f901510888b23eb431b6ba0cb2aee6907))
* let blocks for lifetime ([be79388](https://github.com/MilesCranmer/BorrowChecker.jl/commit/be79388a3cc9060d2c160c05a4e353ab9f38a51d))
* more 3-arg operations on ::Number ([21afdc0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/21afdc0df7e1e12da9fcd2e9fb757f7fbc4700f8))
* prevent passing to thread ([85a2b3e](https://github.com/MilesCranmer/BorrowChecker.jl/commit/85a2b3e229e844a364d2db1256b05d3d8582fdd7))
* prevent variable reassignment ([df43417](https://github.com/MilesCranmer/BorrowChecker.jl/commit/df434177d9c8fde8b9f2aeb0ec280ec4aa6681dc))
* replace `[@own](https://github.com/own)` -&gt; `[@own](https://github.com/own) const`, `[@own](https://github.com/own)_mut` -&gt; `[@own](https://github.com/own)` ([974e683](https://github.com/MilesCranmer/BorrowChecker.jl/commit/974e6839519f5e2e8bc13292442d822fa9db0ac8))
* replace `[@ref](https://github.com/ref)` -&gt; `[@ref](https://github.com/ref) const`, `[@ref](https://github.com/ref)_mut` -&gt; `[@ref](https://github.com/ref)` ([5c3b6f8](https://github.com/MilesCranmer/BorrowChecker.jl/commit/5c3b6f8b705fc5fe88fd3191349f00502092d4b9))
* safer borrow checker with stored lifetime ([665f8ca](https://github.com/MilesCranmer/BorrowChecker.jl/commit/665f8ca52a1d4f2e595d4fe3bd1a2beda34842f7))
* simple borrow checker ([fecc149](https://github.com/MilesCranmer/BorrowChecker.jl/commit/fecc149a37c03a3367312ff42962722d836250c8))
* track symbol in `Owned` for debugging ([b348c65](https://github.com/MilesCranmer/BorrowChecker.jl/commit/b348c65d24606cf1b4e043345fbacf79aa472dac))
* tweak `[@ref](https://github.com/ref)` syntax ([6363629](https://github.com/MilesCranmer/BorrowChecker.jl/commit/6363629a356b797865dd9e51ba60abb840bf6920))


### Bug Fixes

* ambiguity in `==` ([2715246](https://github.com/MilesCranmer/BorrowChecker.jl/commit/2715246ad408365578e232dee3b66ae7352f74a1))
* marked move on wrong scenario ([41938a0](https://github.com/MilesCranmer/BorrowChecker.jl/commit/41938a02495f1b0c3721b291d761619d78331f93))
* out-of-place import ([296bf1f](https://github.com/MilesCranmer/BorrowChecker.jl/commit/296bf1f00e735bcc4a61f3bacc77a1a99e72bd0f))
* prevent nested lifetimes ([3faeed4](https://github.com/MilesCranmer/BorrowChecker.jl/commit/3faeed411677ee5f5d8daffbcf3c7d2497b43767))
* some macro hygiene issues ([c02a3f5](https://github.com/MilesCranmer/BorrowChecker.jl/commit/c02a3f58f774f06312eaec2141b056a7dcdde8df))
