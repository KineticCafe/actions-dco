//// Configuration types for DCO check.
////
//// Config is produced differently by each frontend (action vs CLI) but the core library
//// consumes the same type.

// Parsing rules for 4.0:
//
// - A value of the wrong type is always an error naming the key, except `bots.policy`,
//   which warns and falls back to `none` like an unrecognized value.
// - Keys that existed in 3.x keep a fail-safe path for bad values: the value is dropped
//   or replaced by the safe choice, with a warning. These become errors in 4.1.
// - Keys new in 4.0 (`[ai]`, `bots.exclude-categories`) are strict: any bad value, and
//   any unknown key under `[ai]`, is an error.
// - Unknown keys and tables elsewhere are ignored with a warning (errors in 4.1).

import dco_check/error.{type DcoCheckError}
import dco_check/format
import dco_check/internal/ai_agents
import dco_check/internal/email
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

/// Top-level configuration.
pub type Config {
  Config(
    /// Authors with an implied sign-off (`exempt-authors`).
    exempt_authors: Exemptions,
    /// Which bot accounts are exempt from needing a sign-off (`bots.policy`).
    bots: BotPolicy,
    /// Bot logins exempt under every policy (`bots.allow`).
    bot_allow: List(String),
    /// Bot categories never exempt by policy (`bots.exclude-categories`).
    bot_exclude: List(BotCategory),
    /// AI agent settings (`[ai]`).
    ai: AiConfig,
    /// Commit identity email -> accepted sign-off emails (`alias-signoffs.aliases`).
    aliases: Dict(String, List(String)),
    comment: Bool,
    trailer_parsing: TrailerParsing,
    /// Configuration problems to report. The config module does no I/O; frontends emit
    /// these as warnings.
    warnings: List(String),
  )
}

/// AI agent settings (`[ai]`). AI agents can never certify the DCO: an AI Signed-off-by
/// never satisfies a sign-off requirement and no setting changes that.
pub type AiConfig {
  AiConfig(
    /// What to do with a Signed-off-by naming a known AI agent (`signed-off-by`).
    signed_off_by: AiSignoffPolicy,
    /// What to do with a Co-authored-by naming a known AI agent (`co-authored-by`).
    co_authored_by: AiCheckPolicy,
    /// What to do when a commit's author or committer is a known AI agent and the commit
    /// has no Assisted-by trailer (`trace-detection`).
    trace_detection: AiCheckPolicy,
    /// Addresses to treat as AI agents in addition to the built-in list
    /// (`extra-agent-emails`). Never removes a built-in entry.
    extra_agent_emails: List(String),
    /// Keys of built-in agents that `co-authored-by` and `trace-detection` ignore
    /// (`ignore-agents`). Never affects Signed-off-by handling.
    ignore_agents: List(String),
  )
}

/// What to do with a Signed-off-by that names a known AI agent.
pub type AiSignoffPolicy {
  /// Any AI Signed-off-by fails the commit, whatever else the commit carries (default).
  AiSignoffReject
  /// An AI Signed-off-by is ignored, with a warning, when a human Signed-off-by matching
  /// the commit's author or committer is also present. With no such human sign-off the
  /// commit still fails; bot, author-email and merge exemptions do not count.
  AiSignoffRequireHuman
}

/// The action for an optional AI check.
pub type AiCheckPolicy {
  /// The check does not run (default).
  AiIgnore
  /// A match is reported as a warning; the commit is not failed.
  AiWarn
  /// A match fails the commit.
  AiReject
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
  /// All type: "Bot" commits are exempt.
  AllBots
  /// No bots are exempt (other than those in `bots.allow`).
  NoBots
  /// Well-known bots exempt by category. The list is resolved when parsing and is never
  /// empty; an omitted `bots.categories` means every category.
  WellKnownBots(categories: List(BotCategory))
}

/// Categories of bots.
pub type BotCategory {
  /// Dependency updaters: dependabot[bot], renovate[bot], snyk-bot[bot]
  DependencyUpdaters
  /// CI/CD bots: github-actions[bot]
  CiCd
  /// Release bots: semantic-release[bot], release-please[bot]
  Release
  /// Bot accounts of known AI agents. Only valid in `bots.exclude-categories`: a known AI
  /// agent is never exempt by category.
  AiAgents
}

/// The categories a well-known policy exempts when `bots.categories` is omitted.
pub const well_known_categories = [DependencyUpdaters, CiCd, Release]

/// Default config when no config file is present.
pub fn default() -> Config {
  Config(
    exempt_authors: Exemptions(exact: [], ends_with: []),
    bots: WellKnownBots(categories: well_known_categories),
    bot_allow: [],
    bot_exclude: [],
    ai: default_ai(),
    aliases: dict.new(),
    comment: False,
    trailer_parsing: Strict,
    warnings: [],
  )
}

fn default_ai() -> AiConfig {
  AiConfig(
    signed_off_by: AiSignoffReject,
    co_authored_by: AiIgnore,
    trace_detection: AiIgnore,
    extra_agent_emails: [],
    ignore_agents: [],
  )
}

/// The full AI agent registry for this configuration: built-in agents plus
/// `ai.extra-agent-emails`. Used for Signed-off-by handling and bot exclusion.
pub fn ai_registry(cfg: Config) -> ai_agents.Registry {
  ai_agents.effective(extra_agent_emails: cfg.ai.extra_agent_emails)
}

/// The registry for `ai.co-authored-by` and `ai.trace-detection`: the full registry
/// without the agents in `ai.ignore-agents`.
pub fn ai_relaxed_registry(cfg: Config) -> ai_agents.Registry {
  ai_registry(cfg) |> ai_agents.without(keys: cfg.ai.ignore_agents)
}

/// Format the effective configuration as a list of info-level lines,
/// flagging values that are at their defaults.
pub fn describe(cfg: Config) -> List(String) {
  let dft = default()

  [
    describe_exempt_authors(cfg.exempt_authors, dft.exempt_authors),
    describe_bot_policy(cfg.bots, dft.bots),
    describe_list(
      "bots.exclude-categories",
      list.map(cfg.bot_exclude, category_name),
    ),
    describe_list("bots.allow", cfg.bot_allow),
    describe_value(
      name: "ai.signed-off-by",
      value: ai_signoff_name(cfg.ai.signed_off_by),
      is_default: cfg.ai.signed_off_by == dft.ai.signed_off_by,
    ),
    describe_value(
      name: "ai.co-authored-by",
      value: ai_check_name(cfg.ai.co_authored_by),
      is_default: cfg.ai.co_authored_by == dft.ai.co_authored_by,
    ),
    describe_value(
      name: "ai.trace-detection",
      value: ai_check_name(cfg.ai.trace_detection),
      is_default: cfg.ai.trace_detection == dft.ai.trace_detection,
    ),
    describe_extra_agent_emails(cfg.ai),
    describe_list("ai.ignore-agents", cfg.ai.ignore_agents),
    describe_value(
      name: "trailer-parsing",
      value: case cfg.trailer_parsing {
        Strict -> "strict"
        Lenient -> "lenient"
      },
      is_default: cfg.trailer_parsing == dft.trailer_parsing,
    ),
    describe_value(
      name: "comment",
      value: bool.to_string(cfg.comment) |> string.lowercase,
      is_default: cfg.comment == dft.comment,
    ),
    describe_aliases(cfg.aliases),
  ]
}

fn describe_value(
  name name: String,
  value value: String,
  is_default is_default: Bool,
) -> String {
  case is_default {
    True -> name <> ": " <> value <> " (default)"
    False -> name <> ": " <> value
  }
}

fn describe_list(name: String, values: List(String)) -> String {
  case values {
    [] -> name <> ": none (default)"
    _ -> name <> ": " <> string.join(values, ", ")
  }
}

fn ai_signoff_name(policy: AiSignoffPolicy) -> String {
  case policy {
    AiSignoffReject -> "reject"
    AiSignoffRequireHuman -> "require-human"
  }
}

fn ai_check_name(policy: AiCheckPolicy) -> String {
  case policy {
    AiIgnore -> "ignore"
    AiWarn -> "warn"
    AiReject -> "reject"
  }
}

fn describe_extra_agent_emails(ai: AiConfig) -> String {
  // A count, not the addresses: they may be personal and the action log is public.
  case ai.extra_agent_emails {
    [] -> "ai.extra-agent-emails: none (default)"
    emails ->
      "ai.extra-agent-emails: " <> plural(list.length(emails), "address")
  }
}

fn plural(count: Int, noun: String) -> String {
  case count, noun {
    1, _ -> "1 " <> noun
    n, "address" -> int.to_string(n) <> " addresses"
    n, _ -> int.to_string(n) <> " " <> noun <> "s"
  }
}

fn describe_exempt_authors(
  current: Exemptions,
  default_val: Exemptions,
) -> String {
  use <- bool.guard(
    current == default_val,
    return: "exempt-authors: none (default)",
  )

  describe_list("exempt-authors", list.append(current.exact, current.ends_with))
}

fn describe_bot_policy(current: BotPolicy, default_val: BotPolicy) -> String {
  let value = case current {
    AllBots -> "all"
    NoBots -> "none"
    WellKnownBots(categories:) if categories == well_known_categories ->
      "well-known (all categories)"
    WellKnownBots(categories:) ->
      "well-known ("
      <> list.map(categories, category_name) |> string.join(", ")
      <> ")"
  }
  describe_value(
    name: "bots.policy",
    value:,
    is_default: current == default_val,
  )
}

/// The configuration name of a bot category.
pub fn category_name(cat: BotCategory) -> String {
  case cat {
    DependencyUpdaters -> "dependency-updaters"
    CiCd -> "ci-cd"
    Release -> "release"
    AiAgents -> "ai"
  }
}

fn describe_aliases(aliases: Dict(String, List(String))) -> String {
  case dict.size(aliases) {
    0 -> "alias-signoffs: none (default)"
    _ -> {
      let entries =
        dict.fold(aliases, [], fn(acc, key, values) {
          [key <> " -> " <> string.join(values, ", "), ..acc]
        })
        |> string.join("; ")
      "alias-signoffs: " <> entries
    }
  }
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

/// A parsed value plus the warnings produced while parsing it.
type Parsed(a) =
  Result(#(a, List(String)), DcoCheckError)

const top_level_keys = [
  "exempt-authors", "comment", "trailer-parsing", "bots", "ai", "alias-signoffs",
]

const bots_keys = ["policy", "categories", "exclude-categories", "allow"]

const alias_signoffs_keys = ["aliases"]

const ai_keys = [
  "signed-off-by", "co-authored-by", "trace-detection", "extra-agent-emails",
  "ignore-agents",
]

/// Internal: parse a validated TOML document into Config.
fn parse_doc(doc: Dict(String, tom.Toml)) -> Result(Config, DcoCheckError) {
  use #(exempt_authors, w_exempt) <- result.try(parse_exempt_authors(doc))
  use comment <- result.try(get_bool(
    doc:,
    key: ["comment"],
    default: default().comment,
  ))
  use #(trailer_parsing, w_trailer) <- result.try(parse_trailer_parsing(doc))
  use #(_, w_bots_table) <- result.try(check_bots_table(doc))
  use #(bots, w_policy) <- result.try(parse_bot_policy(doc))
  use bot_exclude <- result.try(parse_exclude_categories(doc))
  use #(bot_allow, w_allow) <- result.try(parse_bot_allow(doc))
  use ai <- result.try(parse_ai(doc))
  use #(aliases, w_aliases) <- result.try(parse_alias_signoffs(doc))

  let w_top =
    unknown_key_warnings(prefix: [], table: doc, known: top_level_keys)

  Ok(Config(
    exempt_authors:,
    bots:,
    bot_allow:,
    bot_exclude:,
    ai:,
    aliases:,
    comment:,
    trailer_parsing:,
    warnings: list.flatten([
      w_exempt,
      w_trailer,
      w_bots_table,
      w_policy,
      w_allow,
      w_aliases,
      w_top,
    ]),
  ))
}

// --- typed accessors -------------------------------------------------------------------

/// Read a boolean. Missing uses `default`; a value of another type is an error.
fn get_bool(
  doc doc: Dict(String, tom.Toml),
  key key: List(String),
  default default: Bool,
) -> Result(Bool, DcoCheckError) {
  case tom.get_bool(doc, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(got:, ..)) ->
      Error(wrong_type(key:, expected: "a boolean", got:))
  }
}

/// Read a string. Missing is `None`; a value of another type is an error.
fn get_string(
  doc: Dict(String, tom.Toml),
  key: List(String),
) -> Result(Option(String), DcoCheckError) {
  case tom.get_string(doc, key) {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(got:, ..)) ->
      Error(wrong_type(key:, expected: "a string", got:))
  }
}

/// Read a table. Missing is `None`; a value of another type is an error.
fn get_table(
  doc: Dict(String, tom.Toml),
  key: List(String),
) -> Result(Option(Dict(String, tom.Toml)), DcoCheckError) {
  case tom.get_table(doc, key) {
    Ok(table) -> Ok(Some(table))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(got:, ..)) ->
      Error(wrong_type(key:, expected: "a table", got:))
  }
}

/// Read an array of strings. Missing is `None`; a value that is not an array, or an array
/// containing anything other than strings, is an error.
fn get_strings(
  doc: Dict(String, tom.Toml),
  key: List(String),
) -> Result(Option(List(String)), DcoCheckError) {
  case tom.get_array(doc, key) {
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(got:, ..)) ->
      Error(wrong_type(key:, expected: "an array of strings", got:))
    Ok(items) -> string_items(key:, items:) |> result.map(Some)
  }
}

/// Like `get_strings`, with a missing key read as an empty list.
fn get_string_list(
  doc: Dict(String, tom.Toml),
  key: List(String),
) -> Result(List(String), DcoCheckError) {
  get_strings(doc, key) |> result.map(option.unwrap(_, []))
}

fn wrong_type(
  key key: List(String),
  expected expected: String,
  got got: String,
) -> DcoCheckError {
  error.ConfigInvalidValue(
    key:,
    message: "expected " <> expected <> ", got " <> describe_got(got),
  )
}

/// Turn the type name in a `tom.WrongType` error into the wording used by `toml_type`.
fn describe_got(got: String) -> String {
  case got {
    "String" -> "a string"
    "Int" -> "an integer"
    "Float" | "Infinity" | "NaN" -> "a float"
    "Bool" -> "a boolean"
    "Array" | "ArrayOfTables" -> "an array"
    "Table" | "InlineTable" -> "a table"
    "Date" | "Time" | "DateTime" -> "a date/time"
    other -> other
  }
}

/// Require every item of a TOML array to be a string. `key` is used in the error.
fn string_items(
  key key: List(String),
  items items: List(tom.Toml),
) -> Result(List(String), DcoCheckError) {
  list.index_map(items, fn(item, index) { #(item, index) })
  |> list.try_map(fn(entry) {
    case entry {
      #(tom.String(s), _) -> Ok(s)
      #(other, index) ->
        Error(error.ConfigInvalidValue(
          key:,
          message: "expected an array of strings, but item "
            <> int.to_string(index + 1)
            <> " is "
            <> toml_type(other),
        ))
    }
  })
}

/// Describe a TOML value's type for error messages.
fn toml_type(value: tom.Toml) -> String {
  case value {
    tom.Int(_) -> "an integer"
    tom.Float(_) | tom.Infinity(_) | tom.Nan(_) -> "a float"
    tom.Bool(_) -> "a boolean"
    tom.String(_) -> "a string"
    tom.Date(_) | tom.Time(_) | tom.DateTime(..) -> "a date/time"
    tom.Array(_) -> "an array"
    tom.ArrayOfTables(_) | tom.Table(_) | tom.InlineTable(_) -> "a table"
  }
}

fn key_name(key: List(String)) -> String {
  string.join(key, ".")
}

/// Warning text for a value that 4.0 tolerates and 4.1 rejects.
fn until_4_1(message: String) -> String {
  message <> " This will be an error in 4.1."
}

/// Warn about keys of `table` that are not in `known`, in sorted order.
fn unknown_key_warnings(
  prefix prefix: List(String),
  table table: Dict(String, tom.Toml),
  known known: List(String),
) -> List(String) {
  dict.keys(table)
  |> list.filter(fn(key) { !list.contains(known, key) })
  |> list.sort(string.compare)
  |> list.map(fn(key) {
    until_4_1(
      "Unknown configuration key "
      <> key_name(list.append(prefix, [key]))
      <> " is ignored.",
    )
  })
}

// --- exempt-authors --------------------------------------------------------------------

fn parse_exempt_authors(doc: Dict(String, tom.Toml)) -> Parsed(Exemptions) {
  let key = ["exempt-authors"]
  use entries <- result.try(get_string_list(doc, key))

  use exemptions <- result.try(
    list.try_fold(entries, Exemptions(exact: [], ends_with: []), fn(acc, entry) {
      case string.starts_with(entry, "@") {
        True ->
          case email.is_domain_pattern(entry) {
            True -> Ok(Exemptions(..acc, ends_with: [entry, ..acc.ends_with]))
            False -> Error(invalid_exemption(key, entry))
          }
        False ->
          case email.is_valid(entry) {
            True -> Ok(Exemptions(..acc, exact: [entry, ..acc.exact]))
            False -> Error(invalid_exemption(key, entry))
          }
      }
    }),
  )

  let warnings =
    entries
    |> list.filter(format.is_noreply)
    |> list.map(fn(entry) {
      until_4_1(
        "exempt-authors: \""
        <> entry
        <> "\" is a no-reply address or domain. A no-reply domain exempts every account that uses it; exempt the specific address, or alias it to your own address with alias-signoffs.aliases.",
      )
    })

  Ok(#(exemptions, warnings))
}

fn invalid_exemption(key: List(String), entry: String) -> DcoCheckError {
  error.ConfigInvalidValue(
    key:,
    message: "\"" <> entry <> "\" is not an email address or an @domain pattern",
  )
}

// --- trailer-parsing -------------------------------------------------------------------

fn parse_trailer_parsing(
  doc: Dict(String, tom.Toml),
) -> Parsed(TrailerParsing) {
  use value <- result.try(get_string(doc, ["trailer-parsing"]))

  case value {
    None | Some("strict") -> Ok(#(Strict, []))
    Some("lenient") -> Ok(#(Lenient, []))
    Some(other) ->
      Ok(
        #(Strict, [
          until_4_1(
            "Unrecognized trailer-parsing \""
            <> other
            <> "\"; using \"strict\". Valid values: \"strict\", \"lenient\".",
          ),
        ]),
      )
  }
}

// --- [bots] ----------------------------------------------------------------------------

/// Type-check `[bots]`, reject the removed `ai-detection` key, and warn about unknown keys.
fn check_bots_table(doc: Dict(String, tom.Toml)) -> Parsed(Nil) {
  use table <- result.try(get_table(doc, ["bots"]))

  case table {
    None -> Ok(#(Nil, []))
    Some(table) ->
      case dict.has_key(table, "ai-detection") {
        True ->
          Error(error.ConfigInvalidValue(
            key: ["bots", "ai-detection"],
            message: "was an experimental setting and has been removed. Remove it; see the [ai] table for the AI agent checks.",
          ))
        False ->
          Ok(#(
            Nil,
            unknown_key_warnings(prefix: ["bots"], table:, known: bots_keys),
          ))
      }
  }
}

/// Parse `bots.policy`. A missing policy uses the default. `allowlist` (deprecated), any
/// unrecognized value, and a value that is not a string become `none` with a warning; they
/// never fall back to `all`. `bots.categories` is type-checked under every policy but only
/// resolved for `well-known`.
fn parse_bot_policy(doc: Dict(String, tom.Toml)) -> Parsed(BotPolicy) {
  use _ <- result.try(get_strings(doc, ["bots", "categories"]))

  case tom.get_string(doc, ["bots", "policy"]) {
    Ok("all") -> Ok(#(AllBots, []))
    Ok("none") -> Ok(#(NoBots, []))
    Error(tom.NotFound(_)) | Ok("well-known") -> parse_categories(doc)
    Ok("allowlist") -> Ok(#(NoBots, [allowlist_deprecation]))
    Ok(other) -> Ok(#(NoBots, [unknown_policy_warning("\"" <> other <> "\"")]))
    Error(tom.WrongType(got:, ..)) ->
      Ok(
        #(NoBots, [
          unknown_policy_warning("(" <> describe_got(got) <> ", not a string)"),
        ]),
      )
  }
}

fn unknown_policy_warning(value: String) -> String {
  until_4_1(
    "Unrecognized bots.policy "
    <> value
    <> "; using \"none\". Valid values: \"all\", \"none\", \"well-known\".",
  )
}

const allowlist_deprecation =
  "bots.policy = \"allowlist\" is deprecated and now behaves as \"none\"; bots.allow applies under every policy. Use policy = \"none\" with bots.allow. This will be an error in 4.1."

/// Resolve `bots.categories` for a well-known policy. Omitted means every category. An
/// empty list, or one with no known categories left after unknown names are dropped, is an
/// error: it would exempt nothing, which is not what `well-known` says.
fn parse_categories(doc: Dict(String, tom.Toml)) -> Parsed(BotPolicy) {
  let key = ["bots", "categories"]
  use names <- result.try(get_strings(doc, key))

  case names {
    None -> Ok(#(WellKnownBots(categories: well_known_categories), []))
    Some([]) ->
      Error(error.ConfigInvalidValue(
        key:,
        message: "is empty. Omit it to exempt every well-known category, or use bots.policy = \"none\".",
      ))
    Some(names) -> {
      use parsed <- result.try(
        list.try_map(names, fn(name) {
          case parse_category_name(name) {
            Ok(AiAgents) ->
              Error(error.ConfigInvalidValue(
                key:,
                message: "\"ai\" is only valid in bots.exclude-categories. A known AI agent is never exempt by category.",
              ))
            Ok(category) -> Ok(Ok(category))
            Error(Nil) -> Ok(Error(name))
          }
        }),
      )

      let categories = list.filter_map(parsed, fn(r) { r }) |> list.unique
      let warnings =
        list.filter_map(parsed, fn(r) {
          case r {
            Ok(_) -> Error(Nil)
            Error(name) ->
              Ok(until_4_1(
                "bots.categories: unknown category \""
                <> name
                <> "\" is ignored. Valid categories: "
                <> valid_categories(well_known_categories)
                <> ".",
              ))
          }
        })

      case categories {
        [] ->
          Error(error.ConfigInvalidValue(
            key:,
            message: "names no known category. Valid categories: "
              <> valid_categories(well_known_categories)
              <> ".",
          ))
        _ -> Ok(#(WellKnownBots(categories:), warnings))
      }
    }
  }
}

fn parse_category_name(name: String) -> Result(BotCategory, Nil) {
  case name {
    "dependency-updaters" -> Ok(DependencyUpdaters)
    "ci-cd" -> Ok(CiCd)
    "release" -> Ok(Release)
    "ai" -> Ok(AiAgents)
    _ -> Error(Nil)
  }
}

fn valid_categories(categories: List(BotCategory)) -> String {
  list.map(categories, fn(c) { "\"" <> category_name(c) <> "\"" })
  |> string.join(", ")
}

/// Parse `bots.exclude-categories` (new in 4.0, strict). Read under every policy.
fn parse_exclude_categories(
  doc: Dict(String, tom.Toml),
) -> Result(List(BotCategory), DcoCheckError) {
  let key = ["bots", "exclude-categories"]
  use names <- result.try(get_string_list(doc, key))

  list.try_map(names, fn(name) {
    parse_category_name(name)
    |> result.replace_error(error.ConfigInvalidValue(
      key:,
      message: "unknown category \""
        <> name
        <> "\". Valid categories: "
        <> valid_categories([AiAgents, ..well_known_categories])
        <> ".",
    ))
  })
  |> result.map(list.unique)
}

/// Parse `bots.allow`. Entries are GitHub logins; an email-shaped entry can never match a
/// login, so it is kept but warned about.
fn parse_bot_allow(doc: Dict(String, tom.Toml)) -> Parsed(List(String)) {
  use logins <- result.try(get_string_list(doc, ["bots", "allow"]))

  let warnings =
    logins
    |> list.filter(fn(login) { string.contains(login, "@") })
    |> list.map(fn(login) {
      until_4_1(
        "bots.allow: \""
        <> login
        <> "\" looks like an email address. bots.allow takes GitHub bot logins, such as \"dependabot[bot]\".",
      )
    })

  Ok(#(logins, warnings))
}

// --- [ai] ------------------------------------------------------------------------------

/// Parse `[ai]` (new in 4.0). Every bad value and every unknown key is an error.
fn parse_ai(doc: Dict(String, tom.Toml)) -> Result(AiConfig, DcoCheckError) {
  let dft = default_ai()
  use table <- result.try(get_table(doc, ["ai"]))
  use <- bool.guard(table == None, return: Ok(dft))

  let table = option.unwrap(table, dict.new())
  use _ <- result.try(
    case
      dict.keys(table)
      |> list.sort(string.compare)
      |> list.find(fn(key) { !list.contains(ai_keys, key) })
    {
      Ok(unknown) ->
        Error(error.ConfigInvalidValue(
          key: ["ai", unknown],
          message: "unknown key. Valid keys: "
            <> string.join(ai_keys, ", ")
            <> ".",
        ))
      Error(Nil) -> Ok(Nil)
    },
  )

  use signed_off_by <- result.try(parse_enum(
    doc:,
    key: ["ai", "signed-off-by"],
    values: [
      #("reject", AiSignoffReject),
      #("require-human", AiSignoffRequireHuman),
    ],
    default: dft.signed_off_by,
  ))
  use co_authored_by <- result.try(parse_enum(
    doc:,
    key: ["ai", "co-authored-by"],
    values: ai_check_values,
    default: dft.co_authored_by,
  ))
  use trace_detection <- result.try(parse_enum(
    doc:,
    key: ["ai", "trace-detection"],
    values: ai_check_values,
    default: dft.trace_detection,
  ))
  use extra_agent_emails <- result.try(parse_extra_agent_emails(doc))
  use ignore_agents <- result.try(parse_ignore_agents(doc))

  Ok(AiConfig(
    signed_off_by:,
    co_authored_by:,
    trace_detection:,
    extra_agent_emails:,
    ignore_agents:,
  ))
}

const ai_check_values = [
  #("ignore", AiIgnore),
  #("warn", AiWarn),
  #("reject", AiReject),
]

/// Read a string enum. Missing uses `default`; anything but a listed value is an error,
/// so a typo cannot silently change what the check does.
fn parse_enum(
  doc doc: Dict(String, tom.Toml),
  key key: List(String),
  values values: List(#(String, a)),
  default default: a,
) -> Result(a, DcoCheckError) {
  use value <- result.try(get_string(doc, key))
  let valid =
    list.map(values, fn(v) { "\"" <> v.0 <> "\"" }) |> string.join(", ")

  case value {
    None -> Ok(default)
    Some(name) ->
      list.key_find(values, name)
      |> result.replace_error(error.ConfigInvalidValue(
        key:,
        message: "unknown value \""
          <> name
          <> "\". Valid values: "
          <> valid
          <> ".",
      ))
  }
}

fn parse_extra_agent_emails(
  doc: Dict(String, tom.Toml),
) -> Result(List(String), DcoCheckError) {
  let key = ["ai", "extra-agent-emails"]
  use emails <- result.try(get_string_list(doc, key))

  list.try_map(emails, fn(address) {
    case email.is_valid(address) {
      True -> Ok(string.lowercase(address))
      False ->
        Error(error.ConfigInvalidValue(
          key:,
          message: "\"" <> address <> "\" is not an email address",
        ))
    }
  })
}

/// Resolve `ai.ignore-agents` to built-in agent keys. Each entry may be an agent key, or
/// one of the agent's emails or bot logins.
fn parse_ignore_agents(
  doc: Dict(String, tom.Toml),
) -> Result(List(String), DcoCheckError) {
  let key = ["ai", "ignore-agents"]
  use references <- result.try(get_string_list(doc, key))

  list.try_map(references, fn(reference) {
    ai_agents.resolve_key(reference)
    |> result.replace_error(error.ConfigInvalidValue(
      key:,
      message: "\""
        <> reference
        <> "\" is not a built-in AI agent key, email address, or bot login",
    ))
  })
  |> result.map(list.unique)
}

// --- [alias-signoffs] ------------------------------------------------------------------

/// Parse `alias-signoffs.aliases`: a table of commit identity email -> array of accepted
/// sign-off emails. Keys and values are lowercased. Type mismatches are errors; a key or
/// entry that is not an email address is dropped with a warning.
fn parse_alias_signoffs(
  doc: Dict(String, tom.Toml),
) -> Parsed(Dict(String, List(String))) {
  let key = ["alias-signoffs", "aliases"]
  use outer <- result.try(get_table(doc, ["alias-signoffs"]))
  let w_outer = case outer {
    Some(table) ->
      unknown_key_warnings(
        prefix: ["alias-signoffs"],
        table:,
        known: alias_signoffs_keys,
      )
    None -> []
  }

  use table <- result.try(get_table(doc, key))
  let entries =
    table
    |> option.unwrap(dict.new())
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })

  use #(aliases, warnings) <- result.try(
    list.try_fold(entries, #(dict.new(), []), fn(acc, entry) {
      let #(identity, value) = entry
      let entry_key = list.append(key, [identity])
      use emails <- result.try(case value {
        tom.Array(items) -> string_items(key: entry_key, items:)
        other ->
          Error(error.ConfigInvalidValue(
            key: entry_key,
            message: "expected an array of strings, got " <> toml_type(other),
          ))
      })
      Ok(add_alias(acc:, identity:, emails:))
    }),
  )

  Ok(#(aliases, list.flatten([w_outer, list.reverse(warnings)])))
}

fn add_alias(
  acc acc: #(Dict(String, List(String)), List(String)),
  identity identity: String,
  emails emails: List(String),
) -> #(Dict(String, List(String)), List(String)) {
  let #(aliases, warnings) = acc
  let invalid = fn(value) {
    until_4_1(
      "alias-signoffs.aliases: \""
      <> value
      <> "\" is not an email address and is ignored.",
    )
  }

  use <- bool.guard(
    !email.is_valid(identity),
    return: #(aliases, [invalid(identity), ..warnings]),
  )

  let #(valid, bad) = list.partition(emails, email.is_valid)
  let warnings =
    list.fold(bad, warnings, fn(ws, value) { [invalid(value), ..ws] })

  case valid {
    [] -> #(aliases, warnings)
    _ -> #(
      dict.insert(
        aliases,
        string.lowercase(identity),
        list.map(valid, string.lowercase),
      ),
      warnings,
    )
  }
}
