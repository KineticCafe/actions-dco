# dco-check Architecture Plan

## Overview

Three layers following the starlist pattern, but substantially simpler:

```
src/
  dco_check.gleam                  <- Core library (public API facade)
  dco_check/
    config.gleam                   <- Config type + TOML parsing
    types.gleam                    <- Domain types (Identity, DcoDisposition, etc.)
    errors.gleam                   <- Unified error type
    internal/
      email.gleam                  <- Email validation (linear scan)
      trailers.gleam               <- Git trailer parsing
      bots.gleam                   <- Well-known bot registry + category resolution
      github/                      <- Generated API client (oaspec)
        types.gleam
        client.gleam
        decode.gleam
        encode.gleam
        request_types.gleam
        response_types.gleam
  dco_check_action.gleam           <- GitHub Action entrypoint
  dco_check_action/
    action_config.gleam            <- Reads action inputs, loads config
  dco_check_cli.gleam              <- CLI entrypoint
  dco_check_cli/
    cli_config.gleam               <- CLI arg parsing, config from args/env
```

## Config

### Source priority

1. Config file (`.github/dco-check.toml` or path from `config-path` input)
2. Embedded config (from `config` input, TOML string)
3. Legacy action inputs (`exempt-authors`, etc.) — emit deprecation warning
   nudging toward config file or embedded config

Legacy inputs continue to work for backwards compat but warn:
"Configuration via action inputs is deprecated. Use a config file
(.github/dco-check.toml) or the config: input. See docs for migration."

A config file with its own CODEOWNER entry gives orgs control over who can
change DCO policy.

### Config format (TOML)

```toml
# Exempt authors - implied DCO sign-off.
# Entries starting with @ are domain patterns; otherwise exact email match.
exempt-authors = [
  "joe@example.net",
  "@example.com",
]

[bots]
# Policy: "all", "well-known", or "allowlist"
policy = "well-known"

# Only used when policy = "well-known". If omitted, all categories enabled.
categories = ["dependency-updaters", "ci-cd"]

# Only used when policy = "allowlist"
allow = ["dependabot[bot]", "renovate[bot]"]
```

### Shared Config type

```gleam
pub type Config {
  Config(
    exempt_authors: Exemptions,
    bots: BotPolicy,
  )
}

pub type Exemptions {
  Exemptions(exact: List(String), ends_with: List(String))
}

pub type BotPolicy {
  /// All type: "Bot" commits are exempt (v2 compat, no config file)
  AllBots
  /// Well-known bots exempt by classification. Empty list = all categories.
  WellKnownBots(categories: List(BotCategory))
  /// Explicit allowlist only
  Allowlist(allow: List(String))
}

pub type BotCategory {
  /// Dependency updaters: dependabot[bot], renovate[bot]
  DependencyUpdaters
  /// CI/CD bots: github-actions[bot]
  CiCd
  /// Release bots: semantic-release[bot], release-please[bot]
  Release
}
```

Parsing `exempt-authors`: split on `@`-prefix to populate `Exemptions`. Same
intelligent behaviour as the current action input parsing — `@example.com` goes
into `ends_with`, everything else into `exact`. Validation: must contain `@`
and `.`, must not have multiple `@`.

AI trailer detection is hardcoded in `internal/bots.gleam` (not configurable).

### Well-known bot registry

Maintained as a const in the source. Grouped by category:

| Category | Bots |
|----------|------|
| DependencyUpdaters | `dependabot[bot]`, `renovate[bot]`, `snyk-bot[bot]` |
| CiCd | `github-actions[bot]` |
| Release | `semantic-release[bot]`, `release-please[bot]` |

Users opt into categories rather than maintaining their own lists. The
`well-known` policy enables all categories by default. Custom category
selection:

```toml
[bots]
policy = "well-known"
categories = ["dependency-updaters", "ci-cd"]
```

### AI trailer detection

Experimental feature. Opt-in via config:

```toml
[bots]
ai-detection = true
```

When enabled, if an exempt bot commit has an AI attribution trailer matching
known patterns (hardcoded in `internal/bots.gleam`), the exemption is revoked
and the commit requires a human sign-off.

Defaults to `false`. Not applied unless explicitly enabled.

- **Action**: reads `config-path` input (default `.github/dco-check.toml`),
  parses TOML. Falls back to legacy inputs with warning. Falls back to AllBots
  if nothing configured.
- **CLI**: reads config from a path argument or defaults. Useful for testing
  without GitHub.

## Core Library (dco_check.gleam)

Public facade exposing:

- `get_dco_status(commits, url, config, total_commits)` ->
  `#(DcoSummary, List(DcoRecord))`
- `format_summary(summary, records)` -> String (for CLI) or structured HTML (for
  action)
- Types: Identity, DcoDisposition, DcoRecord, DcoSummary, Config, etc.

All current logic (evaluate_commit pipeline, check_merge, check_bot,
check_identities, check_signoffs, email validation, exemption matching) lives
here or in submodules.

## Action Runner (dco_check_action.gleam)

- Uses pontil for inputs, logging, job summary.
- Pipeline: read inputs -> load config -> call GitHub API -> get_dco_status ->
  render summary -> write job summary -> set pass/fail.
- Bundled to dist/dco_check.cjs via pontil_build.

## CLI Runner (dco_check_cli.gleam)

- Uses clip for arg parsing, argv for raw args.
- Operates on JSON fixture files (commit comparison response) or possibly local
  git log output.
- Useful for: testing config changes, verifying behaviour against known commits,
  CI debugging.
- No GitHub API call needed - reads data from file.

## Verification Strategy

1. **Unit tests** - test core library functions directly with constructed data.
   No network, no mocking. Cover:
   - Email validation (valid/invalid cases, punycode, edge cases)
   - Trailer parsing (already has tests)
   - Identity resolution
   - Signoff matching (case-insensitive, partial, missing)
   - Exemption matching (exact, domain)
   - Bot detection
   - Full get_dco_status with fixture commits

2. **CLI integration tests** - feed JSON fixtures through the CLI, assert on
   output and exit code. Covers the full pipeline without network.

3. **Action smoke test** - run the bundled action against a test repo with known
   commits (existing workflow test pattern).

## Error Handling

Single error type:

```gleam
pub type DcoError {
  ConfigError(String)
  ApiError(String)
  InputError(String)
}
```

Action calls `pontil.set_failed(errors.to_string(err))`. CLI prints to stderr
and exits non-zero.

## Build and Distribution

- Target: JavaScript (Node.js)
- pontil_build bundles action entrypoint to dist/dco_check.cjs
- CLI runs unbundled via `gleam run -m dco_check_cli`
- action.yml: runs.using: node24, main: dist/dco_check.cjs


## Signoff Aliasing

When a commit identity doesn't match the sign-off email (e.g., dependabot signs
as `support@github.com` but commits as
`49699333+dependabot[bot]@users.noreply.github.com`), aliasing allows the
sign-off to be accepted.

### Config

```toml
[alias-signoffs]
# Opt-in to reading .mailmap from the default branch
with-mailmap = false

# Manual aliases: actual commit email = [accepted sign-off emails]
[alias-signoffs.aliases]
"49699333+dependabot[bot]@users.noreply.github.com" = ["support@github.com"]
```

- `alias-signoffs.aliases` maps a commit identity email to a list of acceptable
  sign-off emails. If a sign-off email appears in the alias list for the
  commit's identity email, it's treated as a match.

  The alias is keyed by commit identity (not by sign-off email) as a safety
  measure: this scopes the alias to a specific committer. The inverted form
  (sign-off email → acceptable committers) would grant a sign-off email blanket
  acceptance power, which could be exploited if someone forges a sign-off using
  that email on an unrelated commit.
- `alias-signoffs.with-mailmap` (future, opt-in): read `.mailmap` from the
  default branch via the GitHub API and apply it to normalize identities before
  matching.

### Policy for reading config and mailmap

Config file and `.mailmap` are read from the **default branch** of the repo (not
the PR head). This prevents a PR from modifying its own DCO policy to pass
checks. The action reads these files via the GitHub API contents endpoint — no
checkout required.

For embedded config (`config:` input), this concern doesn't apply since the
workflow file itself is the source of truth and is already protected by branch
protection / CODEOWNERS.

### Implementation notes

- Aliasing is applied during the matching step: after building identities and
  parsing sign-offs, expand each identity's email with its aliases before
  comparing.
- Well-known bot aliases (dependabot → support@github.com) could be hardcoded
  in the registry as a convenience, but explicit config takes precedence.
- `.mailmap` support is a future feature, gated behind the opt-in flag.

## What Needs to Happen (ordered)

1. Extract types into dco_check/types.gleam (Identity, DcoDisposition,
   DcoRecord, DcoSummary, ExemptionMatch)
2. Extract email validation into dco_check/internal/email.gleam
3. Create dco_check/internal/bots.gleam (well-known registry, category
   resolution, AI trailer detection)
4. Create dco_check/config.gleam with Config + BotPolicy types and TOML parsing
5. Create dco_check/errors.gleam
6. Refactor dco_check.gleam into the public facade (imports from submodules)
7. Create dco_check_action.gleam + dco_check_action/action_config.gleam
   (supports config file, embedded config, and legacy inputs with warning)
8. Create dco_check_cli.gleam + dco_check_cli/cli_config.gleam
9. Write unit tests for email validation
10. Write unit tests for bot policy resolution
11. Write unit tests for get_dco_status with fixture data
12. Wire up summary rendering (HTML for action, text for CLI)
13. Bundle and test action end-to-end
