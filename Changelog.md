# KineticCafe/actions-dco Changelog

## 2.1.0 / 2025-12-17

- Upgraded dependencies.

- Added a possible workaround to [#198][issue-198].

## 2.0.0 / 2025-10-17

- Upgraded dependencies and set runtime as Node v24.

## 1.3.8 / 2025-09-07

- Upgrade dependencies.

## 1.3.7 / 2025-08-23

- Bump version number as it was forgotten for 1.3.6.

## 1.3.6 / 2025-08-17

- Upgrade dependencies.

- Added debug logs to try to debug [#169][issue-169].

- Change `gitSignoffs` to use `String.prototype.matchAll()` instead of
  `Regexp.prototype.exec()`, and to use named capture groups. While I don't
  expect this to fix [#169][issue-169] based on the example data provided, it
  should result in improved pattern matching across multiple commits.

## 1.3.5 / 2025-08-01

- Upgrade dependencies.

## 1.3.4 / 2025-03-01

- Upgrade dependencies.

## 1.3.3 / 2025-02-18

- Upgrade dependencies, resolving a potential security issue.

## 1.3.2 / 2024-12-01

- Upgrade dependencies.

## 1.3.1 / 2024-11-01

- Upgrade dependencies.

- Add CodeQL configuration.

- Switch to Mise for local dependency management instead of NVM with direnv.

## 1.3 / 2024-02-28

- Upgrade dependencies.

- Improved governance documentation, mostly by adding it.

- Switched from ESLint & prettier to Biome.

- Included action / version in the output.

## 1.2 / 2023-09-25

- Upgraded dependencies and set runtime as Node v20.

## 1.1 / 2023-07-21

- Improved error messages using action summaries (`summary` in `@actions/core`).

- Added `exempt-authors` for assumed-permitted (e.g, company-owned open source
  repos automatically permit company emails).

## 1.0 / 2023-06-12

- Initial release. This is a Typescript port of tisonkun/actions-dco set to use
  Node v16.

[issue-169]: https://github.com/KineticCafe/actions-dco/issues/169
[issue-198]: https://github.com/KineticCafe/actions-dco/issues/198
