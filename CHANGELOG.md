# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2025-07-08

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`example` - `v1.2.0`](#example---v120)

---

#### `example` - `v1.2.0`

 - **FEAT**: optimize loading service delay and enhance task queue processing logic.
 - **FEAT**: add CoreService implementation extending BaseCoreService.


## 2025-07-08

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`auth_management` - `v0.0.4`](#auth_management---v004)
 - [`auth_management_database_hive_ce` - `v0.0.3+1`](#auth_management_database_hive_ce---v0031)
 - [`auth_management_database_hive_ce_example` - `v1.2.1`](#auth_management_database_hive_ce_example---v121)
 - [`auth_management_provider_riverpod` - `v0.0.3`](#auth_management_provider_riverpod---v003)
 - [`butterfly_cli` - `v0.0.12+1`](#butterfly_cli---v00121)
 - [`core_management` - `v0.0.5`](#core_management---v005)
 - [`core_management_route_go_router` - `v0.0.3`](#core_management_route_go_router---v003)
 - [`example` - `v1.1.0`](#example---v110)
 - [`auth_management_database_isar_community_example` - `v1.3.1`](#auth_management_database_isar_community_example---v131)
 - [`auth_management_database_isar_community` - `v0.0.4+1`](#auth_management_database_isar_community---v0041)
 - [`auth_management_firebase` - `v0.0.2+2`](#auth_management_firebase---v0022)
 - [`auth_management_firebase_google` - `v0.0.2+2`](#auth_management_firebase_google---v0022)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `auth_management_database_isar_community_example` - `v1.3.1`
 - `auth_management_database_isar_community` - `v0.0.4+1`
 - `auth_management_firebase` - `v0.0.2+2`
 - `auth_management_firebase_google` - `v0.0.2+2`

---

#### `auth_management` - `v0.0.4`

 - **FEAT**: add initialization state to AuthServiceProviderRepository and update AuthManagementRiverpodRepository.

#### `auth_management_database_hive_ce` - `v0.0.3+1`

 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.

#### `auth_management_database_hive_ce_example` - `v1.2.1`

 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.

#### `auth_management_provider_riverpod` - `v0.0.3`

 - **REFACTOR**: remove riverpod and use flutter_riverpod directly.
 - **REFACTOR**: rename AuthManagementIsarRepository to AuthManagementRiverpodRepository.
 - **FEAT**: add initialization state to AuthServiceProviderRepository and update AuthManagementRiverpodRepository.
 - **FEAT**: add initialization check to AuthManagementRiverpodRepository.

#### `butterfly_cli` - `v0.0.12+1`

 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.

#### `core_management` - `v0.0.5`

 - **REFACTOR**: remove initial redirect logic from routing configuration.
 - **REFACTOR**: move in-memory lock repository to top level.
 - **REFACTOR**: Rename error variable in onError.
 - **REFACTOR**: make errorHandlerService public.
 - **REFACTOR**: make errorHandlerService private.
 - **FIX**: correct variable name in onError method.
 - **FEAT**: refactor BaseThemeService to use iTheme for improved theme management.
 - **FEAT**: optimize loading service delay and enhance task queue processing logic.
 - **FEAT**: add CoreService implementation extending BaseCoreService.
 - **FEAT**: add example module to project configuration and optimize loading service initialization.
 - **FEAT**: update theme handling to support context-based brightness and color scheme.
 - **FEAT**: implement CoreLockService with in-memory and persistence options.
 - **FEAT**(core_management): add distributed lock service.
 - **FEAT**: add HexColor extension.
 - **FEAT**: add new helper extension.
 - **FEAT**(go_router): Introduce GoRouterServiceMixin.
 - **FEAT**: add theme getter to BaseCore.
 - **FEAT**: Add BaseThemeService and default implementation.
 - **FEAT**: add loading overlay and service.
 - **FEAT**: add base error handler and integrate into core service.
 - **FEAT**(routing): introduce refreshListenable and observers.

#### `core_management_route_go_router` - `v0.0.3`

 - **REFACTOR**: remove initial redirect logic from routing configuration.
 - **REFACTOR**: Remove redundant navigator key in GoRouterService.
 - **REFACTOR**(router): log route changes in `onRouteChanged`.
 - **FEAT**: improve router redirect logging with enhanced user information.
 - **FEAT**: add initialization state to AuthServiceProviderRepository and update AuthManagementRiverpodRepository.
 - **FEAT**: enhance logging for router redirects with detailed information.
 - **FEAT**(go_router): Introduce GoRouterServiceMixin.
 - **FEAT**(routing): introduce refreshListenable and observers.
 - **FEAT**(router): add route change logging and callback.
 - **FEAT**(route_go_router): Add rootNavigator key to GoRouterService.
 - **DOCS**(go_router): enhance onRouteChanged documentation.
 - **DOCS**: Add detailed documentation for onRouteChanged and goRouterRedirect.

#### `example` - `v1.1.0`

 - **FEAT**: optimize loading service delay and enhance task queue processing logic.
 - **FEAT**: add CoreService implementation extending BaseCoreService.


## 2025-06-10

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`auth_management_database_hive_ce` - `v0.0.3`](#auth_management_database_hive_ce---v003)
 - [`auth_management_database_hive_ce_example` - `v1.2.0`](#auth_management_database_hive_ce_example---v120)
 - [`auth_management_database_isar_community` - `v0.0.4`](#auth_management_database_isar_community---v004)
 - [`auth_management_database_isar_community_example` - `v1.3.0`](#auth_management_database_isar_community_example---v130)
 - [`butterfly_cli` - `v0.0.12`](#butterfly_cli---v0012)
 - [`core_management` - `v0.0.4`](#core_management---v004)
 - [`core_management_route_go_router` - `v0.0.2`](#core_management_route_go_router---v002)

---

#### `auth_management_database_hive_ce` - `v0.0.3`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.

#### `auth_management_database_hive_ce_example` - `v1.2.0`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.

#### `auth_management_database_isar_community` - `v0.0.4`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.

#### `auth_management_database_isar_community_example` - `v1.3.0`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.

#### `butterfly_cli` - `v0.0.12`

 - **FEAT**: display generated model path.

#### `core_management` - `v0.0.4`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.
 - **FEAT**(core): Introduce TaskQueueMixin for safe UI updates.

#### `core_management_route_go_router` - `v0.0.2`

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.


## 2025-04-14

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`auth_management_database_hive_ce` - `v0.0.2`](#auth_management_database_hive_ce---v002)
 - [`auth_management_database_hive_ce_example` - `v1.1.0`](#auth_management_database_hive_ce_example---v110)
 - [`auth_management_database_isar_community` - `v0.0.3`](#auth_management_database_isar_community---v003)
 - [`auth_management_database_isar_community_example` - `v1.2.0`](#auth_management_database_isar_community_example---v120)
 - [`butterfly_cli` - `v0.0.11`](#butterfly_cli---v0011)

---

#### `auth_management_database_hive_ce` - `v0.0.2`

 - **FEAT**(docs): add features page to documentation.

#### `auth_management_database_hive_ce_example` - `v1.1.0`

 - **FEAT**(docs): add features page to documentation.

#### `auth_management_database_isar_community` - `v0.0.3`

 - **FEAT**(docs): add features page to documentation.

#### `auth_management_database_isar_community_example` - `v1.2.0`

 - **FEAT**(docs): add features page to documentation.
 - **FEAT**(riverpod): add auth management provider riverpod.
 - **DOCS**: add.
 - **DOCS**: make example for isar repo.

#### `butterfly_cli` - `v0.0.11`

 - **FEAT**: redirect stdout and stderr from pub commands to the console.


## 2025-02-17

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`auth_management` - `v0.0.3`](#auth_management---v003)
 - [`auth_management_provider_riverpod` - `v0.0.2+1`](#auth_management_provider_riverpod---v0021)
 - [`example` - `v1.1.1`](#example---v111)
 - [`auth_management_database_isar_community` - `v0.0.2+1`](#auth_management_database_isar_community---v0021)
 - [`auth_management_firebase` - `v0.0.2+1`](#auth_management_firebase---v0021)
 - [`auth_management_firebase_google` - `v0.0.2+1`](#auth_management_firebase_google---v0021)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `auth_management_provider_riverpod` - `v0.0.2+1`
 - `example` - `v1.1.1`
 - `auth_management_database_isar_community` - `v0.0.2+1`
 - `auth_management_firebase` - `v0.0.2+1`
 - `auth_management_firebase_google` - `v0.0.2+1`

---

#### `auth_management` - `v0.0.3`

 - **FEAT**: add gen_version command to melos.


## 2025-02-17

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`core_management` - `v0.0.3`](#core_management---v003)

---

#### `core_management` - `v0.0.3`

 - **FEAT**: export core and theme services.


## 2025-02-16

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.10`](#butterfly_cli---v0010)

---

#### `butterfly_cli` - `v0.0.10`

 - **FEAT**: refactor service generation and update core service.


## 2025-02-16

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.9+1`](#butterfly_cli---v0091)

---

#### `butterfly_cli` - `v0.0.9+1`

 - **REFACTOR**: rename framework service to core service.


## 2025-02-16

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.9`](#butterfly_cli---v009)
 - [`core_management` - `v0.0.2`](#core_management---v002)

---

#### `butterfly_cli` - `v0.0.9`

 - **FEAT**: add dependency management and core service.

#### `core_management` - `v0.0.2`

 - **FEAT**: add dependency management and core service.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.8+4`](#butterfly_cli---v0084)

---

#### `butterfly_cli` - `v0.0.8+4`

 - **REFACTOR**: move services and generated files to lib folder.
 - **REFACTOR**: ensure lib folder when creating files.
 - **FIX**: await some process.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.8+3`](#butterfly_cli---v0083)

---

#### `butterfly_cli` - `v0.0.8+3`

 - **FIX**: change mason target branch.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.8+2`](#butterfly_cli---v0082)

---

#### `butterfly_cli` - `v0.0.8+2`

 - **FIX**: change go router mason file path.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.8+1`](#butterfly_cli---v0081)

---

#### `butterfly_cli` - `v0.0.8+1`

 - **FIX**: add dev mode flag to butterfly CLI.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.8`](#butterfly_cli---v008)

---

#### `butterfly_cli` - `v0.0.8`

 - **FEAT**: update dev mode flag to use uppercase 'D'.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.7`](#butterfly_cli---v007)

---

#### `butterfly_cli` - `v0.0.7`

 - **FEAT**: add dev mode flag to butterfly CLI.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.6`](#butterfly_cli---v006)

---

#### `butterfly_cli` - `v0.0.6`

 - **FEAT**: add version command.


## 2025-02-15

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.5`](#butterfly_cli---v005)

---

#### `butterfly_cli` - `v0.0.5`

 - **REFACTOR**: remove non-null assertion for pubspec version.
 - **FEAT**: add butterfly dependency and router type to project config.


## 2025-01-10

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.4+1`](#butterfly_cli---v0041)

---

#### `butterfly_cli` - `v0.0.4+1`

 - **FIX**: bump.


## 2025-01-10

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.4`](#butterfly_cli---v004)

---

#### `butterfly_cli` - `v0.0.4`

 - **FEAT**(Model Generator): Add support for imutable model.


## 2025-01-06

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`auth_management` - `v0.0.2`](#auth_management---v002)
 - [`auth_management_database_isar_community` - `v0.0.2`](#auth_management_database_isar_community---v002)
 - [`auth_management_firebase` - `v0.0.2`](#auth_management_firebase---v002)
 - [`auth_management_firebase_google` - `v0.0.2`](#auth_management_firebase_google---v002)
 - [`auth_management_provider_riverpod` - `v0.0.2`](#auth_management_provider_riverpod---v002)
 - [`butterfly_cli` - `v0.0.3`](#butterfly_cli---v003)
 - [`example` - `v1.1.0`](#example---v110)

---

#### `auth_management` - `v0.0.2`

 - **FEAT**(riverpod): add auth management provider riverpod.
 - **FEAT**: add repo class for manageging auth management via provider and non provider like firebase.
 - **FEAT**: add version.

#### `auth_management_database_isar_community` - `v0.0.2`

 - **FEAT**(riverpod): add auth management provider riverpod.
 - **DOCS**: add.
 - **DOCS**: make example for isar repo.

#### `auth_management_firebase` - `v0.0.2`

 - **FEAT**(riverpod): add auth management provider riverpod.
 - **FEAT**: add sign in with google mixin for native and web.
 - **FEAT**: add sign in with google mixin for native and web.

#### `auth_management_firebase_google` - `v0.0.2`

 - **FEAT**: add sign in with google mixin for native and web.
 - **FEAT**: add sign in with google mixin for native and web.

#### `auth_management_provider_riverpod` - `v0.0.2`

 - **FEAT**(riverpod): add auth management provider riverpod.

#### `butterfly_cli` - `v0.0.3`

 - **FEAT**: add.
 - **FEAT**: make.
 - **FEAT**(riverpod): add auth management provider riverpod.
 - **DOCS**: add.
 - **DOCS**: wip.
 - **DOCS**: wip.

#### `example` - `v1.1.0`

 - **FEAT**(riverpod): add auth management provider riverpod.
 - **DOCS**: add.
 - **DOCS**: make example for isar repo.


## 2024-10-26

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.2`](#butterfly_cli---v002)

---

#### `butterfly_cli` - `v0.0.2`

 - **REFACTOR**: change to kDebugMode so more dart style.
 - **REFACTOR**: change some method name.
 - **FIX**: chnage version const to better name with prefix of K.
 - **FIX**: handle empty string for user model name.
 - **FEAT**: make.
 - **FEAT**: make commit command can accept option to pre determine commit for conventional action.
 - **FEAT**: make verbose more config global without calling initilize method.
 - **FEAT**: add verbose support.
 - **FEAT**: make a generator for version file.
 - **FEAT**: make a generator for version file.
 - **FEAT**: backward config support mechanism.
 - **FEAT**: add config to use core or not.
 - **FEAT**: add commit command to help with conventional commit.
 - **FEAT**: add commit command to help with conventional commit.
 - **FEAT**: add new command to help with conventional commit.
 - **DOCS**: add todo.


## 2024-10-13

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`butterfly_cli` - `v0.0.1`](#butterfly_cli---v001)

---

#### `butterfly_cli` - `v0.0.1`

 - Bump "butterfly_cli" to `0.0.1`.

