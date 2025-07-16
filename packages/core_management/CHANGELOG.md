## 0.2.0

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**(auth): add OAuth2 management package.

## 0.1.0

> Note: This release has breaking changes.

 - **BREAKING** **REFACTOR**: extract auth logic from GoRouterService to GoRouterAuthRoute mixin.
 - **BREAKING** **FEAT**: add example for go_router package.

## 0.0.6+1

 - **DOCS**: add documentation for RouteService mixin and update existing docs.

## 0.0.6

 - **FEAT**: enhance user getter with detailed error handling for authentication requirements.

## 0.0.5

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

## 0.0.4

 - **FEAT**(core_management_route_go_router): Introduce GoRouterService for route management.
 - **FEAT**(core): Introduce TaskQueueMixin for safe UI updates.

## 0.0.3

 - **FEAT**: export core and theme services.

## 0.0.2

 - **FEAT**: add dependency management and core service.

## 0.0.1

* TODO: Describe initial release.
