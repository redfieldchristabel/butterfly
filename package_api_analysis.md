# Package API Analysis Report

## Summary

**9 packages analyzed** across **2 library groups** (Core, Auth).

**Existing docs location**: `/home/hayabusa/StudioProjects/butterfly/docs/libraries/`
**Sidebar config**: `/home/hayabusa/StudioProjects/butterfly/docs.json`

---

## docs.json Sidebar (expected structure)

```
Getting Started:
  - Getting to know Butterfly  (/)
  - Installation               (/installation)
  - Features                   (/features)
Libraries:
  - Core:
    - Introduction             (/libraries/core)
    - Route Service            (/libraries/core/features/route_service)
    [MISSING: enqueue, hex_color, screen_layout features exist as files but NOT in sidebar]
  - Auth:
    - Introduction             (/libraries/auth)
    [MISSING: all feature pages - sidebar only has Introduction]
```

---

## 1. core_management

**Description**: "A new Flutter project." (generic - no real description)
**Version**: 0.3.0
**Purpose**: Foundation services for Flutter apps — error handling, theme, loading, routing, utilities.

### Exported Public API (`core_management.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `BaseCoreService` | abstract class (singleton) | Service locator base; provides errorHandler(), getTheme(), loadingService, errorHandlerService, themeService |
| `BaseThemeService` | abstract class | Theme management with ColorScheme.fromSeed, custom appBar/card/button/bottomSheet themes, exposes CoreTypographyTheme |
| `BaseErrorHandlerService` | abstract class | onError(FlutterErrorDetails), onPlatformError(Object, StackTrace) |
| `BaseLoadingService` | abstract class | Loading UI; provides ButterflyLoadingController + abstract loadingWidget() |
| `BaseRouteService` | abstract class | Route config with navigatorKey, redirectOverride, temporaryRedirect, observers, errorBuilder, abstract routerConfig |

### Public API NOT in barrel export (but in lib/ top-level, not src/)

| Symbol | Type | File | Description |
|--------|------|------|-------------|
| `CoreLockService` | class | `services/core_lock.dart` | Distributed locking service with in-memory + optional persistent storage; acquire/release/isLocked/getLockExpiry/cleanup |
| `LockPersistence` | abstract class | `repositories/lock.dart` | Interface for persistent lock storage: createOrUpdateLock, getLockExpiry, deleteLock, watchLockRelease, cleanupExpiredLocks |
| `RouteServiceMixin` | mixin on `BaseCoreService` | `mixins/router_service.dart` | Mixin to add routeService getter + routerConfig to BaseCoreService |
| `BaseAuthRoute<T>` | mixin on `BaseRouteService` | `mixins/auth_route.dart` | Auth-aware routing: user, authTriggerRoutes, defaultAuthRoute, signInRoute, signUpRoute, publicRoutes |
| `ScreenLayoutExtension` | extension on `BuildContext` | `extensions/screen_layout.dart` | screenSize, shortestSide, mobileLayout, themeData |
| `HexColor` | extension on `Color` | `extensions/hex_color.dart` | fromHex(String), toHex({leadingHashSign, withOpacityFormat}) |
| `TaskQueueMixin<T>` | mixin on `State<T>` | `mixins/task_queue.dart` | Deferred task execution queue for widgets; enqueue(VoidCallback) |
| `CoreTypographyTheme` | class | `core_typography_theme.dart` | Wraps Material TextTheme with full style getters (displayLarge..labelSmall, plus primary* variants) + textSelectionTheme |
| `LoadingOverlay` | StatefulWidget | `widgets/loading_overlay.dart` | Full-screen overlay for loading states; wraps child in Overlay with listenable |
| `ButterflyLoadingController<T>` | class (ChangeNotifier) | `widgets/loading_overlay.dart` | Loading state with auto-transition from completed→idle; state, data |
| `ButterflyLoadingState` | enum | `widgets/loading_overlay.dart` | Values: idle, loading, completed |

### Internal-only (under src/ — NOT public API)

| Symbol | Type | Description |
|--------|------|-------------|
| `DefaultThemeService` | class extends BaseThemeService | Default empty theme service |
| `DefaultLoadingService` | class extends BaseLoadingService | Shows CupertinoActivityIndicator |
| `DefaultErrorHandler` | class extends BaseErrorHandlerService | Default empty error handler |

---

## 2. core_management_route_go_router

**Version**: Depends on core_management
**Purpose**: GoRouter integration for the core route service.

### Exported Public API (`core_management_route_go_router.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `GoRouterService` | abstract class extends `BaseRouteService` | GoRouter config: routes, refreshListenable, onRouteChanged, routeLog, goRouterRedirect, routerConfig getter |

### Public API NOT in barrel export

| Symbol | Type | File | Description |
|--------|------|------|-------------|
| `GoRouterServiceMixin` | mixin on `BaseCoreService` implements `RouteServiceMixin` | `router_service_mixin.dart` | Bridges GoRouterService into BaseCoreService via RouteServiceMixin |
| `GoRouterAuthRoute<T>` | abstract class extends `GoRouterService` with `BaseAuthRoute<T>` | `go_router_auth_route.dart` | Full auth-aware GoRouter with roleBasedRedirect, auth route protection, temporary redirect handling |

---

## 3. auth_management

**Description**: "A library to help with auth management in flutter project"
**Version**: 0.3.0
**Purpose**: Abstract auth service layer — repository pattern for auth state management.

### Exported Public API (`auth_management.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `AuthServiceRepository<T>` | abstract class (singleton) | Core auth service: currentUser, initialize(), signOut(), streamUser(), getUser(), onUserChanged(), fetchUser(), dbRepo, providerRepo |
| `AuthManagementDatabaseRepository<T>` | abstract interface class (singleton) | Database persistence interface: getUser(), addUser(), clearUser(), streamUser() |
| `AuthManagementException` | class implements Exception | Auth exception with title, message, code |
| `InMemoryDatabaseRepository<T>` | class implements `AuthManagementDatabaseRepository` | In-memory ValueNotifier-backed implementation |

### Exported via `auth_management_provider.dart`

| Symbol | Type | Description |
|--------|------|-------------|
| `AuthServiceProviderRepository<T>` | abstract class | Provider binding interface: bindUserToProvider(), getUser(), clearUser(), initialized flag |

---

## 4. auth_management_database_hive_ce

**Purpose**: Hive CE (Community Edition) database backend for auth user persistence.

### Exported Public API (`auth_management_database_hive_ce.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `AuthManagementDatabaseHiveCe<T extends BaseUser>` | class implements `AuthManagementDatabaseRepository<T>` | Hive CE implementation: initialize(), addUser, clearUser, getUser, streamUser |
| `BaseUser` | class extends `HiveObject` | Base Hive user model class |

---

## 5. auth_management_database_isar_community

**Purpose**: Isar Community Edition database backend for auth user persistence.

### Exported Public API (`auth_management_database_isar_community.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `AuthManagementIsarRepository<T extends BaseUser>` | class implements `AuthManagementDatabaseRepository<T>` | Isar implementation: initialize(CollectionSchema), addUser, clearUser, getUser, streamUser |
| `BaseUser` | class | Base Isar user model with Id field (note: .g.dart generation is commented out) |

---

## 6. auth_management_firebase

**Purpose**: Firebase Authentication integration.

### Exported via `auth_management_firebase.dart`

| Symbol | Type | Description |
|--------|------|-------------|
| `FirebaseAuthManagementRepository<T>` | abstract class implements `AuthServiceRepository<T>` | Firebase auth: signInWithEmailAndPassword, signOut, getUser, streamUser, morphUser, fetchUser |

### Exported via `auth_management_firebase_google.dart`

| Symbol | Type | Description |
|--------|------|-------------|
| `SignInWithGoogleWebMixin` | mixin | Google sign-in for web: signInWithGoogle (popup), signInWithGoogleRedirect, scopes, customParameters |

---

## 7. auth_management_firebase_google

**Purpose**: Native Google Sign-In (Android/iOS) for Firebase.

### Exported Public API (`auth_management_firebase_google.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `SignInWithGoogleFirebase` | mixin on `FirebaseAuthManagementRepository` | signInWithGoogle() using GoogleSignIn plugin for native platforms |

---

## 8. auth_management_oauth2

**Purpose**: OAuth2 authentication flows.

### Exported Public API (`auth_management_oauth2.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `BaseOauth2AuthManagement` | abstract class extends `AuthServiceRepository` | OAuth2 base: authorizationEndpoint, identifier, secret, getClient(), storeClient(), http.Client |
| `AuthorizationCodeGrantMixin` | mixin on `BaseOauth2AuthManagement` | Authorization Code Grant flow: signInWithAuthorizationCode(), tokenEndpoint, redirectUrl, redirect() |
| `ClientCredential` | mixin on `BaseOauth2AuthManagement` | Client Credentials Grant: signInWithClientCredential() |
| `ResourceOwnerPasswordGrant` | mixin on `BaseOauth2AuthManagement` | Resource Owner Password Grant: signInWithPassword({username, password}) |

---

## 9. auth_management_provider_riverpod

**Purpose**: Riverpod state management integration for auth.

### Exported Public API (`auth_management_provider_riverpod.dart`)

| Symbol | Type | Description |
|--------|------|-------------|
| `AuthManagementRiverpodRepository<T extends RiverpodUser>` | class extends `AuthServiceProviderRepository<T>` | Riverpod provider: initialize(WidgetRef), bindUserToProvider, clearUser, getUser |
| `RiverpodUser` | mixin | Mixin for riverpod-compatible user models |
| `RiverpodUserState` | Riverpod `Notifier<RiverpodUser?>` (generated via @riverpod) | `$RiverpodUserState` notifier with linkUser(), clearUser(); provides `riverpodUserStateProvider` |

---

## Documentation Coverage Analysis

### Core Library (`docs/libraries/core/`)

| Page | File exists? | In sidebar? | Covers? |
|------|-------------|-------------|---------|
| `index.mdx` (Introduction) | YES | YES | Mentions BaseCoreService, error handling, theme, loading; lists 4 feature links |
| `features/enqueue.mdx` | YES | **NO** | TaskQueueMixin + enqueue() |
| `features/hex_color.mdx` | YES | **NO** | HexColor extension |
| `features/route_service.mdx` | YES | YES | GoRouterService / RouteService |
| `features/screen_layout.mdx` | YES | **NO** | ScreenLayoutExtension |

### Auth Library (`docs/libraries/auth.mdx`)

| Page | File exists? | In sidebar? | Covers? |
|------|-------------|-------------|---------|
| `auth.mdx` (Introduction) | YES | YES | **EMPTY** — no content beyond frontmatter |

### What's COMPLETELY MISSING from docs

**Core Library — undocumented symbols:**
- `CoreLockService` + `LockPersistence` — distributed locking
- `CoreTypographyTheme` — typography theme wrapper
- `LoadingOverlay` widget + `ButterflyLoadingController` + `ButterflyLoadingState` 
- `BaseLoadingService` / `BaseThemeService` / `BaseErrorHandlerService` — only mentioned in passing
- `BaseAuthRoute<T>` mixin — auth routing
- `RouteServiceMixin` — route service mixin

**Auth Library — everything is undocumented:**
- `AuthServiceRepository<T>` — core auth service
- `AuthManagementDatabaseRepository<T>` — database repo interface
- `InMemoryDatabaseRepository<T>` — in-memory impl
- `AuthServiceProviderRepository<T>` — provider binding
- `AuthManagementException` — exception class
- Database backends (hive_ce, isar_community)
- Firebase integrations (FirebaseAuthManagementRepository, SignInWithGoogleWebMixin, SignInWithGoogleFirebase)
- OAuth2 flows (BaseOauth2AuthManagement, AuthorizationCodeGrantMixin, ClientCredential, ResourceOwnerPasswordGrant)
- Riverpod provider (AuthManagementRiverpodRepository, RiverpodUser, RiverpodUserState)

**Sidebar — pages missing from docs.json:**
- `/libraries/core/features/enqueue`
- `/libraries/core/features/hex_color`
- `/libraries/core/features/screen_layout`
- `/libraries/core/features/service_locator` (BaseCoreService)
- `/libraries/core/features/theme` (BaseThemeService)
- `/libraries/core/features/error_handler` (BaseErrorHandlerService)
- `/libraries/core/features/loading` (LoadingOverlay, ButterflyLoadingController)
- `/libraries/core/features/lock` (CoreLockService)
- `/libraries/core/features/typography` (CoreTypographyTheme)
- All Auth feature pages

---

## Files Created

`/home/hayabusa/StudioProjects/butterfly/package_api_analysis.md` — this full report.
