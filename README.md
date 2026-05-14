# @KineticCafe/actions-dco

Enforce the presence of commit sign-offs on pull requests, indicating that the
contributor to a project certifies that they are permitted to contribute to the
project. The sign-off line represents certification of the
[Developer Certificate of Origin][dco].

## Example Usage

```yaml
name: DCO Check

on:
  pull_request:

permissions: {}

jobs:
  check:
    permissions:
      contents: read

    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v3.1.0
```

## Versioning

From version 3.0, only exact semantic version tags (`@v3.1.0`, `@v3.1.0`, etc.)
will be published. We no longer allow floating tags as part of our repository
configuration.

## Inputs

- `repo-token`: The GitHub token for use with this action. It must have
  permission to read pull request details. If `comment` is enabled in config,
  add `pull-requests: write`.

  Default: `${{ github.token }}`

- `config`: Embedded TOML configuration (see [Configuration](#configuration)
  below). This is the preferred way to configure the action.

- `exempt-authors` (_deprecated_): A whitespace-separated list of email
  exemption patterns. Use the `config` input instead. A deprecation warning will
  be emitted when this input is used. This value will be ignored if present in
  both action input and in the `config` input.

## Configuration

Configuration is managed as inline TOML via the `config` input.

### Minimal example

```yaml
- uses: KineticCafe/actions-dco@v3.1.0
  with:
    config: |
      exempt-authors = ["joe@example.net", "@example.com"]
```

### Author Exemption

Commit authors may be exempted by policy with implied sign-off on the DCO. This
is a TOML list of email patterns. Two formats are allowed in this list:

- Exact email addresses (`name@example.org`), matching only those author email
  addresses

- Domain patterns beginning with `@` (`@example.org`), matching any author email
  address ending with that domain.

`exempt-authors` are applied only for the commit _author_. The commit
_committer_ cannot exempt other peoples' contributions.

```toml
exempt-authors = ["joe@example.net", "@example.com"]
```

### Trailer Parsing Strictness

The action now reads Git trailers like `git interpret-trailers` does, including
proper handling of folded trailer values. The default behaviour is `"strict"`
parsing and it may be configured with the `trailer-parsing` configuration
option.

- `trailer-parsing = "strict"`: Strict parsing. All trailers must be collected
  in a single block with no blank lines:

  ```gitcommit
  feat: add widget

  This implements the widget feature.

  Reviewed-by: Bob <bob@example.com>
  Signed-off-by: Alice
    <alice@example.com>
  ```

  If there were a blank line between `Reviewed-by` and `Signed-off-by`, the
  `reviewed-by` trailer is not visible.

- `trailer-parsing = "lenient"`: Lenient parsing. Trailer blocks may be
  separated by blank lines:

  ```gitcommit
  feat: add widget

  This implements the widget feature.

  Reviewed-by: Bob <bob@example.com>

  Signed-off-by: Alice
    <alice@example.com>
  ```

For both parsing configurations, any non-trailer text prevents any trailers from
being found:

```gitcommit
feat: add widget

This implements the widget feature.

Reviewed-by: Bob <bob@example.com>
Signed-off-by: Alice
  <alice@example.com>

Body text after sign-off.
```

The presence of "Body text after sign-off" prevents the trailers from being
found as they no longer "trail" the body.

### Pull Request Comment

`actions-dco` will now add or update a pull request comment if `comment = true`
is present in the configuration. This is disabled by default, as it requires an
additional permission on the job token.

```yaml
name: DCO Check

on:
  pull_request:

permissions: {}

jobs:
  check:
    permissions:
      contents: read
      pull-requests: write # Track DCO results in a comment on the pull request

    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v3.1.0
        with:
          config: |
            comment = true
```

### Bot Configuration

`actions-dco` versions 1 and 2 always exempted bot authors. As this may be
undesirable with large model contributions, it is now possible to configure a
bot policy. All controls are under the `bot` namespace.

#### Policy (`bot.policy`)

`bot.policy` may be set to one of four values and control the overall operation.
The default is `"all"`

| Policy         | Behaviour                                                              |
| -------------- | ---------------------------------------------------------------------- |
| `"all"`        | All `type: "Bot"` commits are exempt (default)                         |
| `"none"`       | No bots are exempt; all require valid sign-offs                        |
| `"well-known"` | Only recognized bots are exempt, by category, enables `bot.categories` |
| `"allowlist"`  | Only explicitly listed bot logins are exempt, enables `bot.allow`      |

```toml
bot.policy = "all"

[bot]
policy = "well-known"
```

#### Well-Known Bot Categories (`bot.categories`)

If exemptions are made only for `well-known` bots, then the categories for
permitted bots may be specified. If `bot.policy = "well-known"` with no
`bot.categories`, all categories are assumed.

Supported categories are:

- `dependency-updaters`: `dependabot[bot]`, `renovate[bot]`, `snyk-bot[bot]`
- `ci-cd`: `github-actions[bot]`
- `release`: `semantic-release[bot]`, `release-please[bot]`

Additional categories may be added if required.

#### Explicitly Allowed Bots (`bot.allow`)

If `bot.policy = "allowlist"`, then a list of explicitly permitted bot
**logins** must be provided. These are _not_ email addresses on GitHub.

```toml
bot.allow = ["dependabot[bot]", "semantic-release[bot]"]
```

### Aliased Sign-offs

you can now also alias sign-offs to match the commit. This is _similar_ to the
git `mailmap` file. The `alias-signoffs.aliases` is a map of commit identity
emails to the typically presented `Signed-off-by:` identity.

For example, Dependabot commits with
`49699333+dependabot[bot]@users.noreply.github.com`, but signs off with
`support@github.com`.

This applies to _all committers_, not just bots.

```toml
[alias-signoffs.aliases]
"49699333+dependabot[bot]@users.noreply.github.com" = ["support@github.com"]
```

## How it works

For each commit in the pull request:

1. Commits with multiple parents are skipped (they are merge commits);
2. Commits by bots are checked against the configured bot policy.
3. Identity extraction and validation verifies that at least one of the commit
   _author_ and the commit _committer_ have both `name` and `email` values.
4. When `signed-off-by` trailers are found, they are parsed and matched against
   commit identities. Sign-off trailers must have both a name and a valid email
   address.
5. Without a `signed-off-by` trailer, the author email is checked against
   exemption patterns.

## PR Comments

When `comment = true` is set in configuration, the action will create or update
a comment on the pull request with the DCO check results. This requires
`pull-requests: write` permission:

```yaml
permissions:
  pull-requests: write

steps:
  - uses: KineticCafe/actions-dco@v3.1.0
    with:
      config: |
        comment = true
```

## Migration from v2

- The `exempt-authors` input still works but emits a deprecation warning. Move
  to the `config` input with TOML format. If `exempt-authors` is present as both
  an action input _and_ in the `config` TOML, a warning will be presented and
  the action input _will be ignored_.

- Bot exemption behaviour is unchanged by default (all bots exempt). Use
  `bots.policy = "well-known"` or `"none"` for stricter control. Future versions
  will change this to `"well-known"`.

- The action now validates sign-off email addresses and requires both name and
  email in the `Signed-off-by` trailer.

## Licence

[Apache License, version 2.0](LICENCE.md)

[dco]: https://developercertificate.org
[licence.md]: https://github.com/KineticCafe/actions-dco/blob/main/LICENCE.md
[welcomes contributions]: https://github.com/KineticCafe/actions-dco/blob/main/CONTRIBUTING.md
