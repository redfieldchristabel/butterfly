## Unreleased

 - **FEAT**: add `butterfly generate model <Name> --cocoon` (with
   `--collection`) to scaffold a Cocoon `@Collection` model from a template,
   and `butterfly cocoon migrate [args...]` / `butterfly cocoon build` to run
   the project's own `dart run cocoon_generator:migrate` / `dart run
   build_runner build -d` with inherited stdio and unchanged exit codes.
 - **FEAT**: expose `generate_cocoon_model` and the read-only
   `cocoon_migrate_check` tools on the MCP server.
 - **DOCS**: the `cocoon_migrate_check` tool description and the README state
   why `migrate --check` is the only exposed migrate tool (migrate is a
   development tool, not a CI step) and that the lock file is `cocoon.lock`.
 - **FIX**: restore the process working directory after `FrameworkService`
   tests change it.

## 0.2.0

> Note: This release has breaking changes.

 - **REFACTOR**: remove non-null assertion for pubspec version.
 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.
 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.
 - **REFACTOR**: move services and generated files to lib folder.
 - **REFACTOR**: rename framework service to core service.
 - **REFACTOR**: rename framework service to core service.
 - **REFACTOR**: move services and generated files to lib folder.
 - **REFACTOR**: ensure lib folder when creating files.
 - **REFACTOR**: ensure lib folder when creating files.
 - **REFACTOR**: remove non-null assertion for pubspec version.
 - **FIX**: change go router mason file path.
 - **FIX**: await some process.
 - **FIX**: await some process.
 - **FIX**: change mason target branch.
 - **FIX**: change mason target branch.
 - **FIX**: change go router mason file path.
 - **FIX**: add dev mode flag to butterfly CLI.
 - **FIX**: add dev mode flag to butterfly CLI.
 - **FIX**: bump.
 - **FIX**: bump.
 - **FEAT**: display generated model path.
 - **FEAT**: add dependency management and core service.
 - **FEAT**: add dependency management and core service.
 - **FEAT**: redirect stdout and stderr from pub commands to the console.
 - **FEAT**: add.
 - **FEAT**: redirect stdout and stderr from pub commands to the console.
 - **FEAT**: add.
 - **FEAT**: refactor service generation and update core service.
 - **FEAT**: update dev mode flag to use uppercase 'D'.
 - **FEAT**: update dev mode flag to use uppercase 'D'.
 - **FEAT**: add dev mode flag to butterfly CLI.
 - **FEAT**: add dev mode flag to butterfly CLI.
 - **FEAT**: add version command.
 - **FEAT**(Model Generator): Add support for imutable model.
 - **FEAT**: add butterfly dependency and router type to project config.
 - **FEAT**: add butterfly dependency and router type to project config.
 - **FEAT**: refactor service generation and update core service.
 - **FEAT**: display generated model path.
 - **FEAT**(Model Generator): Add support for imutable model.
 - **FEAT**: add version command.
 - **DOCS**: add.
 - **DOCS**: add.
 - **DOCS**: wip.
 - **DOCS**: wip.
 - **DOCS**: wip.
 - **DOCS**: wip.
 - **BREAKING** **FEAT**(auth): add OAuth2 management package.
 - **BREAKING** **FEAT**(auth): add OAuth2 management package.

## 0.1.0

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**(auth): add OAuth2 management package.

## 0.0.12+1

 - **REFACTOR**(auth_management_database_hive_ce): use git dependency for auth_management.

## 0.0.12

 - **FEAT**: display generated model path.

## 0.0.11

 - **FEAT**: redirect stdout and stderr from pub commands to the console.

## 0.0.10

 - **FEAT**: refactor service generation and update core service.

## 0.0.9+1

 - **REFACTOR**: rename framework service to core service.

## 0.0.9

 - **FEAT**: add dependency management and core service.

## 0.0.8+4

 - **REFACTOR**: move services and generated files to lib folder.
 - **REFACTOR**: ensure lib folder when creating files.
 - **FIX**: await some process.

## 0.0.8+3

 - **FIX**: change mason target branch.

## 0.0.8+2

 - **FIX**: change go router mason file path.

## 0.0.8+1

 - **FIX**: add dev mode flag to butterfly CLI.

## 0.0.8

 - **FEAT**: update dev mode flag to use uppercase 'D'.

## 0.0.7

 - **FEAT**: add dev mode flag to butterfly CLI.

## 0.0.6

 - **FEAT**: add version command.

## 0.0.5

 - **REFACTOR**: remove non-null assertion for pubspec version.
 - **FEAT**: add butterfly dependency and router type to project config.

## 0.0.4+1

 - **FIX**: bump.

## 0.0.4

 - **FEAT**(Model Generator): Add support for imutable model.

## 0.0.3

 - **FEAT**: add.
 - **FEAT**: make.
 - **FEAT**(riverpod): add auth management provider riverpod.
 - **DOCS**: add.
 - **DOCS**: wip.
 - **DOCS**: wip.

## 0.0.2

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

## 0.0.1

 - Bump "butterfly_cli" to `0.0.1`.

## 1.0.0

- Initial version.
