//// Configuration types for DCO check.
////
//// Config is produced differently by each frontend (action vs CLI) but the core library
//// consumes the same type.

import dco_check/error.{type DcoCheckError}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom

/// Top-level configuration.
pub type Config {
  Config(
    /// Authors to exempt from
    exempt_authors: Exemptions,
    bots: BotPolicy,
    ai_detection: Bool,
    aliases: dict.Dict(String, List(String)),
    comment: Bool,
    trailer_parsing: TrailerParsing,
  )
}

/// Exemptions for DCO processing: exact email addresses or domain completions.
pub type Exemptions {
  Exemptions(exact: List(String), ends_with: List(String))
}

/// Trailer parsing mode.
pub type TrailerParsing {
  /// Only the final paragraph is considered as trailers.
  Strict
  /// Walk backwards through blank-line-separated blocks accumulating trailers.
  Lenient
}

/// Bot exemption policy.
pub type BotPolicy {
  /// All type: "Bot" commits are exempt (v2 compat, no config file).
  AllBots
  /// No bots are exempt.
  NoBots
  /// Well-known bots exempt by classification. Empty list = all categories.
  WellKnownBots(categories: List(BotCategory))
  /// Explicit allowlist only.
  Allowlist(allow: List(String))
}

/// Categories of well-known bots.
pub type BotCategory {
  /// Dependency updaters: dependabot[bot], renovate[bot], snyk-bot[bot]
  DependencyUpdaters
  /// CI/CD bots: github-actions[bot]
  CiCd
  /// Release bots: semantic-release[bot], release-please[bot]
  Release
}

/// Default config when no config file is present (mostly v2 backwards compatible).
pub fn default() -> Config {
  Config(
    exempt_authors: Exemptions(exact: [], ends_with: []),
    bots: AllBots,
    ai_detection: False,
    aliases: dict.new(),
    comment: False,
    trailer_parsing: Strict,
  )
}

/// Load config from a TOML file.
pub fn load(path: String) -> Result(Config, DcoCheckError) {
  case simplifile.read(path) {
    Ok(content) -> parse(content)
    Error(reason) -> Error(error.ConfigFileError(path:, reason:))
  }
}

/// Parse a TOML string into Config.
/// Rejects configs containing a 'ref' key — that is only valid as the sole
/// key in a default branch config file (handled by parse_default_branch_config).
pub fn parse(content: String) -> Result(Config, DcoCheckError) {
  use doc <- result.try(
    tom.parse(content) |> result.map_error(error.ConfigParseError),
  )

  // 'ref' is never valid in a standard config
  case dict.has_key(doc, "ref") {
    True ->
      Error(error.ConfigInvalidRef(
        "'ref' is not a valid configuration key. A 'ref' pointing to a remote config is only valid as the sole key in a default branch config file (.github/dco-check.toml or .dco-check.toml).",
      ))
    False -> parse_doc(doc)
  }
}

/// Result of parsing a default branch config file.
/// It's either a direct standard config, or a ref URL to fetch.
pub type DefaultBranchConfig {
  DirectConfig(Config)
  RefConfig(url: String)
}

/// Parse a default branch config file. This may be:
/// - A ref-only file: TOML with a single key 'ref' whose value is an HTTPS URL
/// - A standard config file (which must NOT contain 'ref')
pub fn parse_default_branch_config(
  content: String,
) -> Result(DefaultBranchConfig, DcoCheckError) {
  use doc <- result.try(
    tom.parse(content) |> result.map_error(error.ConfigParseError),
  )

  case dict.size(doc), dict.has_key(doc, "ref") {
    0, _ -> Ok(DirectConfig(default()))
    1, True -> {
      // Single key 'ref' — must be a string HTTPS URL
      case tom.get_string(doc, ["ref"]) {
        Ok(url) -> validate_ref_url(url)
        Error(_) ->
          Error(error.ConfigInvalidRef(
            "'ref' must be a string containing an HTTPS URL.",
          ))
      }
    }
    _, True ->
      Error(error.ConfigInvalidRef(
        "'ref' must be the only key in a config reference file. Either use 'ref' alone to point to a remote config, or provide a full configuration without 'ref'.",
      ))
    _, False -> {
      use cfg <- result.try(parse_doc(doc))
      Ok(DirectConfig(cfg))
    }
  }
}

/// Validate that a ref URL is HTTPS.
fn validate_ref_url(url: String) -> Result(DefaultBranchConfig, DcoCheckError) {
  use <- bool.guard(
    string.starts_with(url, "https://"),
    return: Ok(RefConfig(url:)),
  )
  Error(error.ConfigInvalidRef("'ref' must be an HTTPS URL, got: " <> url))
}

/// Internal: parse a validated TOML document into Config.
fn parse_doc(
  doc: dict.Dict(String, tom.Toml),
) -> Result(Config, DcoCheckError) {
  let exempt_authors = parse_exempt_authors(doc)
  let bots = parse_bot_policy(doc)
  let ai_detection =
    tom.get_bool(doc, ["bots", "ai-detection"]) |> result.unwrap(False)
  let aliases = parse_aliases(doc)
  let comment = tom.get_bool(doc, ["comment"]) |> result.unwrap(False)
  let trailer_parsing = case tom.get_string(doc, ["trailer-parsing"]) {
    Ok("lenient") -> Lenient
    _ -> Strict
  }

  Ok(Config(
    exempt_authors:,
    bots:,
    ai_detection:,
    aliases:,
    comment:,
    trailer_parsing:,
  ))
}

fn parse_exempt_authors(doc: dict.Dict(String, tom.Toml)) -> Exemptions {
  let entries =
    tom.get_array(doc, ["exempt-authors"])
    |> result.unwrap([])
    |> list.filter_map(fn(v) {
      case v {
        tom.String(s) -> Ok(s)
        _ -> Error(Nil)
      }
    })

  list.fold(entries, Exemptions(exact: [], ends_with: []), fn(acc, entry) {
    case string.starts_with(entry, "@") {
      True -> Exemptions(..acc, ends_with: [entry, ..acc.ends_with])
      False -> Exemptions(..acc, exact: [entry, ..acc.exact])
    }
  })
}

fn parse_bot_policy(doc: dict.Dict(String, tom.Toml)) -> BotPolicy {
  case tom.get_string(doc, ["bots", "policy"]) {
    Ok("all") -> AllBots
    Ok("none") -> NoBots
    Ok("well-known") -> {
      let categories =
        tom.get_array(doc, ["bots", "categories"])
        |> result.unwrap([])
        |> list.filter_map(fn(v) {
          case v {
            tom.String("dependency-updaters") -> Ok(DependencyUpdaters)
            tom.String("ci-cd") -> Ok(CiCd)
            tom.String("release") -> Ok(Release)
            _ -> Error(Nil)
          }
        })
      WellKnownBots(categories:)
    }
    Ok("allowlist") -> {
      let allow =
        tom.get_array(doc, ["bots", "allow"])
        |> result.unwrap([])
        |> list.filter_map(fn(v) {
          case v {
            tom.String(s) -> Ok(s)
            _ -> Error(Nil)
          }
        })
      Allowlist(allow:)
    }
    _ -> AllBots
  }
}

fn parse_aliases(
  doc: dict.Dict(String, tom.Toml),
) -> dict.Dict(String, List(String)) {
  tom.get_table(doc, ["alias-signoffs", "aliases"])
  |> result.unwrap(or: dict.new())
  |> dict.fold(dict.new(), fn(acc, key, value) {
    case value {
      tom.Array(items) ->
        dict.insert(acc, string.lowercase(key), parse_alias_emails(items))
      _ -> acc
    }
  })
}

fn parse_alias_emails(items: List(tom.Toml)) -> List(String) {
  list.filter_map(items, fn(v) {
    case v {
      tom.String(s) -> Ok(string.lowercase(s))
      _ -> Error(Nil)
    }
  })
}
