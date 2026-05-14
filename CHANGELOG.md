# KineticCafe/actions-dco Changelog

## 3.1.0 / 2026-05-15

- Reshaped the sign-off summary written to the action and optionally as a commit
  comment. The message as added with 3.0.0 was accurate but meaningless. It has
  now be modified to produce meaningful summaries.

  Each commit that fails (up to X commits) will be included in a DCO failure
  table:

  ```markdown
  | Commit     | Subject                       | Issue                    |
  | ---------- | ----------------------------- | ------------------------ |
  | `ff882225` | deps: Bump the actions group… | No Signed-off-by trailer |
  ```

  When commits are passed, skipped or exempt, they are included in a "pass"
  table grouped by the identity responsible that signed off:

  ```markdown
  | Identity                | Commits                        |
  | ----------------------- | ------------------------------ |
  | dependabot[bot]         | 1 (bot, skipped)               |
  | Alice <al…@example.org> | 2 (signed off)                 |
  | Bob <bob@example.com>   | 1 (exempt domain @example.com) |
  ```

  The comment will be headed with a subject indicating that the check was
  successful or failed as a whole.

- Fixed a pathological bug where parsing trailers in Lenient mode would result
  in quadratic time parsing. This wouldn't have been noticeable initially except
  for a separate bug where some experimental minimal AI assistant checking was
  always executed and ran trailer parsing in Lenient mode, even though the
  default trailer parsing rule is Strict.

  > We apologize for the fault in the subtitles. Those responsible have been
  > sacked.

  This has been resolved by improving the parsing to operate on split graphemes,
  and all trailer parsing has been modified to short circuit on the block (if a
  trailer is not present on the first line of the block, it's not a trailer
  block) and the line (trailers must have `:`; if not present, it's not a
  trailer line).

  > We apologize again for the fault in the subtitles. Those responsible for
  > sacking the people who have just been sacked have been sacked.

  This results in a 4½x improvement in Strict trailer parsing and a 11x
  improvement in Lenient trailer parsing.

- Added additional debug messages.

- Upgraded to pontil 2 and `pontil_summary` 1.1 and modified the CLI to use an
  improved ANSI-aware output mode.

## 3.0.0 / 2026-05-09

Version 3 is a full rewrite in Gleam, targeting JavaScript. It _should_ be
mostly compatible with previous versions. Malformed commits or sign-off trailers
are no longer treated as partial matches, which will result in those commits
being rejected where earlier versions may have produced a subtly incorrect
validation.

For security purposes, `actions-dco` is released with immutable releases and
tags with no floating version tags. You muse use `@v3.0.0` instead of `@v3`.
Pinning to the specific tag reference is strongly recommended.

### Deprecations and Stricter Validation

- The `exempt-authors` input is deprecated, and its use will emit a deprecation
  warning. Configuration is now provided via an embedded `TOML` configuration
  (`config`).

- Commit identity parsing has been made more strict. The previous version of
  `actions-dco` would compose a user and email combination from _both_ the
  author and the committer if either was missing its `name` or `email` fields.
  Given a case where the commit author only had `jane@example.org` in her email,
  and the committer only had `John Committer`, the action would synthesize an
  identity `John Committer <jane@example.org>`.

  This no longer happens.

- Git trailers are strictly parsed. Previous versions would read the
  `signed-off-by` trailer from anywhere in the commit message. Now, they must be
  properly positioned as Git trailers with some flexibility by using
  `trailer-parsing = "lenient"`.

- Sign-off trailers MUST have both name and email fields.

### New Features

- TOML configuration. For the initial version, `actions-dco` supports inline
  configuration with the `config` input. Future versions will support config
  file references. Eventually, inline `config` will be deprecated and removed as
  external configuration is safer.

- Bot policies: Bot committers have been ignored by default since the first
  version of `actions-dco`, but this need not be the case any further. Bots may
  be configured to require explicit `signed-off-by` trailers (`none`), only
  `well-known` bots (which can be restricted further by `bot.categories`), or
  only specific bots are exempted (`allowlist` with `bot.allow`).

- Sign-off aliasing. When using the web interface for committing, you may be
  prompted to use your private Git commit alias, but you might still set
  `signed-off-by` to your habitual signature. This allows commit identities to
  be mapped to a different value for sign-off validation.

- Pull request comments: With `comment = true` in the configuration (off by
  default) and `pull-requests: write` job permission, `actions-dco` will now
  maintain a comment on the DCO validation within the PR, increasing the
  visibility of the sign-off check.

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
