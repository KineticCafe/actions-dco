# @KineticCafe/actions-dco

Enforce the presence of commit sign-offs on pull requests, indicating that the
contributor to a project certifies that they are permitted to contribute to
the project. The sign-off line represents certification of the
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
      - uses: KineticCafe/actions-dco@v4.0.1
```

## Versioning

This project does not publish floating version tags. There is no `v4` tag.

## Inputs

- `repo-token`: The GitHub token for use with this action. It must have
  permission to read pull request details. If `comment` is enabled in config,
  add `pull-requests: write`.

  Default: `${{ github.token }}`

- `config`: Embedded TOML configuration (see [Configuration](#configuration)
  below). Use either this or a default branch configuration file, not both: if
  a default branch configuration file exists and `config` is also set, the run
  fails.

## Configuration

Configuration is managed as TOML, either inline TOML via the `config` input or
a [Default Branch Configuration](#default-branch-configuration) file. Use one
or the other: if a default branch configuration file exists and the `config`
input is also set, the run fails.

Configuration parsing is strict; enforcement of some rules is lenient in 4.0.
Parsing errors will be hard failures in a future version.

### Minimal example

```yaml
- uses: KineticCafe/actions-dco@v4.0.1
  with:
    config: |
      exempt-authors = ["joe@example.net", "@example.com"]
```

A fully documented example is in
[dco-check-example.toml](dco-check-example.toml).

### Author Exemption

Commit _authors_ may have an implied sign-off on the DCO written in
`exempt-authors`.

- Exact email addresses (`name@example.org`), matching only those author email
  addresses

- Domain patterns beginning with `@` (`@example.org`), matching any author
  email address ending with that domain.

Committers are never exempt, only authors.

```toml
exempt-authors = ["joe@example.net", "@example.com"]
```

Each entry must be an email address or an `@domain` pattern; anything else is
an error. Comparison is case-insensitive.

Entries should not include `noreply` or `no-reply`. To exempt your own GitHub
no-reply address, alias it to an exempt address (see
[Aliased Sign-offs](#aliased-sign-offs)).

### Trailer Parsing Strictness

The action now reads Git trailers like `git interpret-trailers` does,
including proper handling of folded trailer values. The default behaviour is
`"strict"` parsing and it may be configured with the `trailer-parsing`
configuration option.

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

For both parsing configurations, any non-trailer text prevents any trailers
from being found:

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

`actions-dco` can add or update a pull request comment when `comment = true`.
This is disabled by default, as it requires an additional permission on the
job token.

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
      - uses: KineticCafe/actions-dco@v4.0.1
        with:
          config: |
            comment = true
```

The comment and the job summary are public. Personal email addresses are
masked (`al…@example.org`) in both. No-reply addresses (such as
`49699333+dependabot[bot]@users.noreply.github.com`) and the addresses of
built-in AI agents are shown in full.

### Bot Configuration

#### Policy (`bots.policy`)

Commits by bot accounts (GitHub `type: "Bot"`) may be exempt from sign-off
requirements by specifying `bots.policy`.

| Policy         | Behaviour                                              |
| -------------- | ------------------------------------------------------ |
| `"well-known"` | Only recognized bots are exempt, by category (default) |
| `"all"`        | All `type: "Bot"` commits are exempt                   |
| `"none"`       | No bots are exempt; all require valid sign-offs        |

```toml
[bots]
policy = "well-known"
```

With version 4, the default is no longer `all`, but `well-known`. Support for
`allowlist` as a policy has been removed (it acts like `none`). Unsupported
values report a warning and behave as "none".

#### Well-Known Bot Categories (`bots.categories`)

Categories of bots not requiring sign-offs when `bots.policy = "well-known"`.
If this configuration is omitted, all categories are assumed set; an empty
list is an error.

- `ci-cd`: `github-actions[bot]`
- `dependency-updaters`: `dependabot[bot]`, `renovate[bot]`, `snyk-bot[bot]`
- `release`: `release-please[bot]`, `semantic-release[bot]`

```toml
[bots]
policy = "well-known"
categories = ["dependency-updaters"]
```

Unknown categories are ignored with a warning, unless the final list of
categories is empty.

#### Excluded Bot Categories (`bots.exclude-categories`)

If `bots.policy = "all"`, sign-offs can be required on categories of bots by
specifying `exclude-categories`.

- `ai`: built-in known AI agents
- `ci-cd`: `github-actions[bot]`
- `dependency-updaters`: `dependabot[bot]`, `renovate[bot]`, `snyk-bot[bot]`
- `release`: `release-please[bot]`, `semantic-release[bot]`

The `ai` category (only usable in this configuration option) covers the bot
accounts of known AI agents (for example `claude[bot]` or Copilot); included
agents without bot logins are ignored.

```toml
[bots]
policy = "all"
exclude-categories = ["ai"]
```

#### Explicitly Allowed Bots (`bots.allow`)

`bots.allow` lists bot **logins** (not email addresses) that do not require
sign-offs. It applies under every `bots.policy` and overrides
`exclude-categories`.

```toml
[bots]
allow = ["dependabot[bot]", "semantic-release[bot]"]
```

`bots.allow` only decides whether a bot account requires a sign-off. It has no
effect on the AI agent checks.

### AI Agents

Bots and AI agents cannot certify the [Developer Certificate of Origin][dco]
by definition. In `actions-dco`, the `bots` configuration options provide some
leeway to strictly mechanical bots like Dependabot. The configuration options
here only provide stricter enforcement along three lines:

1. Agents are _never_ permitted to provide a `Signed-off-by` trailer.
2. Agents _should not_ claim authorship with `Co-authored-by` trailers.
3. Agents _should_ specify an `Assisted-by` trailer.

AI violations of these rules are mechanical matches against the built-in
registry of AI agents.

| Agents                                                                 |
| ---------------------------------------------------------------------- |
| Aider, Amazon Q Developer, Augment Code, Bito, Claude Code, CodeRabbit |
| Codeflash, Codegen, Continue, Crush, Cubic, Cursor, Devin, Ellipsis    |
| Factory Droid, GitHub Copilot, Google Gemini, Google Jules, Greptile   |
| Kiro, Korbit, Lovable, Mentat, OpenAI Codex, OpenCode, OpenHands, Qodo |
| Qwen Code, Replit, Sourcery, Warp                                      |

> This list was created by Kiro and only some entries are verified. These
> entries could be out of date or incorrect. Pull requests to correct errors
> or add additional common cases are welcome.

The AI checks run before every other check: bots, author exemptions, and
commit type exemptions may be rejected for AI failures.

#### AI `Signed-off-by` (`ai.signed-off-by`)

The presence of a `Signed-off-by` matching a known AI agent rejects the
commit.

| Value             | Behaviour                                         |
| ----------------- | ------------------------------------------------- |
| `"reject"`        | Reject AI sign-offs (default)                     |
| `"require-human"` | Warn if a valid non-AI `Signed-off-by` is present |

The `"require-human"` behaviour is still strict: if an AI agent has inserted a
`Signed-off-by` trailer, there _must_ be a valid `Signed-off-by` trailer. It
cannot be an _inferred_ sign-off from `exempt-authors`. When an invalid AI
sign-off is detected, the row will be marked in the results.

`ai.ignore-agents` does not affect this check; `ai.extra-agent-emails` _does_.

```toml
[ai]
signed-off-by = "require-human"
```

#### AI `Co-authored-by` (`ai.co-authored-by`)

The presence of a `Co-authored-by` trailer matching a known AI agent can warn
on or reject the commit. If enabled, a warning will be included indicating
that the `Assisted-by` trailer should be used instead of `Co-authored-by`.

```gitcommit
Assisted-by: <agent harness> [model] [tool…]
```

This check is more opinionated, aligning with the [AI policy](AI_POLICY.md)
adopted by `actions-dco`. It is disabled by default, and specific agents may
be exempted from this check with `ai.ignore-agents`.

| Value      | Behaviour                                                      |
| ---------- | -------------------------------------------------------------- |
| `"ignore"` | No check (default)                                             |
| `"warn"`   | A warning recommending `Assisted-by`; the commit is not failed |
| `"reject"` | The commit fails, with a recommendation to use `Assisted-by`   |

```toml
[ai]
co-authored-by = "reject"
```

`ai.extra-agent-emails` extends the agents covered under this check.

#### AI Authors and Committers (`ai.trace-detection`)

The presence of a known AI agent as the commit author or committer _without_
an `Assisted-by` trailer can warn on or reject the commit. If enabled, a
warning will be included that the `Assisted-by` trailer should be used.

As with `ai.co-authored-by`, this check is more opinionated and is disabled by
default. Specific agents may be exempted from this check with
`ai.ignore-agents`.

| Value      | Behaviour                                                      |
| ---------- | -------------------------------------------------------------- |
| `"ignore"` | No check (default)                                             |
| `"warn"`   | A warning recommending `Assisted-by`; the commit is not failed |
| `"reject"` | The commit fails, with a recommendation to use `Assisted-by`   |

```toml
[ai]
trace-detection = "warn"
```

The check can only see declared or recognizable AI use. A person who runs an
agent under their own identity and adds no trailer leaves nothing to detect.
`ai.extra-agent-emails` extends the agents covered under this check.

#### Additional Agent Addresses (`ai.extra-agent-emails`)

Add email addresses to treat as AI agents beyond the built-in registry. Each
entry must be an email address, masked in output.

```toml
[ai]
extra-agent-emails = ["agent@example.com"]
```

#### Ignoring Specific Agents (`ai.ignore-agents`)

Built-in agents listed here are ignored by `ai.co-authored-by` and
`ai.trace-detection`. An entry may be the agent's key or any of its email
addresses or bot logins; all of these name the same agent:

```toml
[ai]
ignore-agents = [
  "github-copilot",
  "copilot-swe-agent[bot]",
  "167198135+copilot[bot]@users.noreply.github.com",
]
```

Unknown agents are rejected as an error.

### Aliased Sign-offs

Sign-offs may be aliased to match the commit. This is _similar_ to the git
`mailmap` file. The `alias-signoffs.aliases` is a map of commit identity
emails to the typically presented `Signed-off-by:` identity.

For example, Dependabot commits with
`49699333+dependabot[bot]@users.noreply.github.com`, but signs off with
`support@github.com`.

This applies to _all committers_, not just bots. Only the email is aliased:
the sign-off name must still match the commit identity's name.

```toml
[alias-signoffs.aliases]
"49699333+dependabot[bot]@users.noreply.github.com" = ["support@github.com"]
```

Aliases also apply to [author exemption](#author-exemption). If a commit's
author has no sign-off and their own address is not exempt, each of the
author's alias addresses is checked against `exempt-authors`. Only the
author's aliases count, and only one hop: an alias address is not itself
looked up as an alias. The results name the author and note the alias (masked
in the comment and job summary).

```toml
exempt-authors = ["@zieglers.ca"]

[alias-signoffs.aliases]
"123+me@users.noreply.github.com" = ["austin@zieglers.ca"]
```

Keys and addresses must be email addresses. In 4.0 an invalid one is ignored
with a warning; in 4.1 it will be an error.

### Default Branch Configuration

For security purposes, `actions-dco` will always check the default branch of
the repo for the existence of either `.github/dco-check.toml` or
`.dco-check.toml` in the root directory.

If either is found, it will be parsed to produce an `actions-dco`
configuration. The `config` input must not also be set: if both exist, the run
fails.

The parsed configuration file may be a standard configuration file (described
above) or a TOML file with a single root level key: `ref` that has a URL
value.

```toml
# A remote reference.
ref = "https://raw.github.com/other/repo/blob/main/config/actions-dco.toml"
```

This `ref` value _must_ be the only key in the file and the value _must_ be an
HTTPS URL. This allows for centralized configuration. If the provided URL
matches the API URL (e.g., `https://api.github.com/*`), it will be requested
with the configured API token. Otherwise, the configuration file will be
requested without any authentication.

HTTP Redirects will be followed, but the result must be a valid _standard_
configuration TOML file and not another `ref` configuration file. The presence
of a `ref` configuration in a _standard_ configuration TOML file will be
flagged as an error.

If the file exists (any value other than 404 is returned) and does not parse,
it will error out and `actions-dco` will report the error. Symlinks are not
supported, only real files at `.github/dco-check.toml` or `.dco-check.toml`.

## How it works

For each commit in the pull request:

1. A `Signed-off-by` matching a known AI agent rejects the commit, unless
   `ai.signed-off-by = "require-human"` applies and a human sign-off is
   present. No exemption overrides this.
2. With `ai.co-authored-by`, a `Co-authored-by` matching a known AI agent
   warns about or rejects the commit.
3. With `ai.trace-detection`, a known AI agent as author or committer, with no
   `Assisted-by` trailer, warns about or rejects the commit.
4. Merge commits (more than one parent) without a `Signed-off-by` trailer pass
   and are reported as skipped. A merge commit that carries a `Signed-off-by`
   (for example from `git merge --signoff`) is checked like any other commit.
5. Commits by bots are checked against `bots.allow`, `bots.exclude-categories`
   and the bot policy.
6. Identity extraction and validation verifies that at least one of the commit
   _author_ and the commit _committer_ have both `name` and `email` values.
7. When `signed-off-by` trailers are found, they are parsed and matched
   against commit identities. Sign-off trailers must have both a name and a
   valid email address. AI agent sign-offs never match. The results list the
   identity whose sign-off matched.
8. Without a `signed-off-by` trailer, the author email, then each of its
   aliases, is checked against exemption patterns.

## PR Comments

When `comment = true` is set in configuration, the action will create or
update a comment on the pull request with the DCO check results. This requires
`pull-requests: write` permission:

```yaml
permissions:
  pull-requests: write

steps:
  - uses: KineticCafe/actions-dco@v4.0.1
    with:
      config: |
        comment = true
```

## Migration from v3

- The `exempt-authors` action input was deprecated in v3 and has been removed
  in v4. Use `exempt-authors` in the TOML configuration.

- The default bot policy is `"well-known"` instead of `"all"`. Bots outside
  the well-known list (including AI bots such as Copilot) now require a
  sign-off. Set `bots.policy = "all"` to keep the old behaviour, or list
  specific bots in `bots.allow`.

- `bots.allow` applies under every policy. `bots.policy = "allowlist"` has
  been removed and acts the same as `"none"`. The `bots.allow` entries still
  apply.

- If a known AI agent is referenced in a `Signed-off-by` trailer, the commit
  will be rejected. As the Linux Kernel policies on coding assistants says:
  "AI agents MUST NOT add Signed-off-by tags. Only humans can legally certify
  the Developer Certificate of Origin (DCO)."

- Merge commits are no longer always skipped. One that carries a
  `Signed-off-by` is checked.

- The TOML configuration is stricter than it was under v3.

## Licence

[Apache License, version 2.0](LICENCE.md)

[dco]: https://developercertificate.org
