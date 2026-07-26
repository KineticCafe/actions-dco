import dco_check/config.{
  AllBots, Allowlist, CiCd, DependencyUpdaters, Exemptions, Lenient, NoBots,
  Release, Strict, WellKnownBots,
}
import gleam/dict
import gleam/list
import gleam/string
import take

// --- empty config ---

pub fn parse_empty_string_returns_default_test() {
  let assert Ok(cfg) = config.parse("")
  assert cfg == config.default()
}

// --- exempt-authors ---

pub fn parse_exact_email_exemption_test() {
  let assert Ok(cfg) = config.parse("exempt-authors = [\"joe@example.com\"]")
  assert cfg.exempt_authors
    == Exemptions(exact: ["joe@example.com"], ends_with: [])
}

pub fn parse_domain_pattern_exemption_test() {
  let assert Ok(cfg) = config.parse("exempt-authors = [\"@example.com\"]")
  assert cfg.exempt_authors
    == Exemptions(exact: [], ends_with: ["@example.com"])
}

pub fn parse_mixed_exemptions_test() {
  let assert Ok(cfg) =
    config.parse(
      "exempt-authors = [\"joe@example.com\", \"@corp.dev\", \"alice@other.org\"]",
    )
  // fold builds lists in reverse
  assert cfg.exempt_authors
    == Exemptions(exact: ["alice@other.org", "joe@example.com"], ends_with: [
      "@corp.dev",
    ])
}

// --- trailer-parsing ---

pub fn parse_trailer_parsing_strict_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"strict\"")
  assert cfg.trailer_parsing == Strict
}

pub fn parse_trailer_parsing_lenient_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"lenient\"")
  assert cfg.trailer_parsing == Lenient
}

pub fn parse_trailer_parsing_unknown_defaults_strict_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"bogus\"")
  assert cfg.trailer_parsing == Strict
}

// --- comment ---

pub fn parse_comment_true_test() {
  let assert Ok(cfg) = config.parse("comment = true")
  assert cfg.comment == True
}

pub fn parse_comment_false_test() {
  let assert Ok(cfg) = config.parse("comment = false")
  assert cfg.comment == False
}

// --- bot policy ---

pub fn parse_bot_policy_all_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"all\"")
  assert cfg.bots == AllBots
}

pub fn parse_bot_policy_none_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"none\"")
  assert cfg.bots == NoBots
}

pub fn parse_bot_policy_well_known_all_categories_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"well-known\"")
  assert cfg.bots == WellKnownBots(categories: [])
}

pub fn parse_bot_policy_well_known_specific_categories_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"well-known\"\ncategories = [\"ci-cd\", \"release\"]",
    )
  assert cfg.bots == WellKnownBots(categories: [CiCd, Release])
}

pub fn parse_bot_policy_well_known_ignores_unknown_categories_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"well-known\"\ncategories = [\"ci-cd\", \"made-up\"]",
    )
  assert cfg.bots == WellKnownBots(categories: [CiCd])
}

pub fn parse_bot_policy_allowlist_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"allowlist\"\nallow = [\"dependabot[bot]\", \"renovate[bot]\"]",
    )
  assert cfg.bots == Allowlist(allow: ["dependabot[bot]", "renovate[bot]"])
}

pub fn parse_bot_policy_missing_defaults_all_test() {
  let assert Ok(cfg) = config.parse("comment = true")
  assert cfg.bots == AllBots
}

// --- conflicting/irrelevant bot fields are ignored ---

pub fn parse_bot_allow_ignored_when_policy_all_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"all\"\nallow = [\"dependabot[bot]\"]\ncategories = [\"ci-cd\"]",
    )
  assert cfg.bots == AllBots
}

pub fn parse_bot_allow_ignored_when_policy_none_test() {
  let assert Ok(cfg) =
    config.parse("[bots]\npolicy = \"none\"\nallow = [\"dependabot[bot]\"]")
  assert cfg.bots == NoBots
}

pub fn parse_bot_categories_ignored_when_policy_allowlist_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"allowlist\"\nallow = [\"mybot[bot]\"]\ncategories = [\"ci-cd\"]",
    )
  assert cfg.bots == Allowlist(allow: ["mybot[bot]"])
}

pub fn parse_bot_allow_ignored_when_policy_well_known_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"well-known\"\ncategories = [\"dependency-updaters\"]\nallow = [\"mybot[bot]\"]",
    )
  assert cfg.bots == WellKnownBots(categories: [DependencyUpdaters])
}

// --- aliases ---

pub fn parse_aliases_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"bot@users.noreply.github.com\" = [\"support@github.com\"]",
    )
  assert dict.get(cfg.aliases, "bot@users.noreply.github.com")
    == Ok(["support@github.com"])
}

pub fn parse_aliases_lowercases_keys_and_values_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"BOT@Example.COM\" = [\"Support@GitHub.COM\"]",
    )
  assert dict.get(cfg.aliases, "bot@example.com") == Ok(["support@github.com"])
}

// --- ai-detection ---

pub fn parse_ai_detection_true_test() {
  let assert Ok(cfg) = config.parse("[bots]\nai-detection = true")
  assert cfg.ai_detection == True
}

pub fn parse_ai_detection_default_false_test() {
  let assert Ok(cfg) = config.parse("")
  assert cfg.ai_detection == False
}

// --- default branch config parsing ---

pub fn default_branch_empty_file_returns_defaults_test() {
  let assert Ok(config.DirectConfig(cfg)) =
    config.parse_default_branch_config("")
  assert cfg == config.default()
}

pub fn default_branch_standard_config_parses_test() {
  let assert Ok(config.DirectConfig(cfg)) =
    config.parse_default_branch_config(
      "exempt-authors = [\"@example.com\"]\ncomment = true",
    )
  assert cfg.exempt_authors
    == Exemptions(exact: [], ends_with: ["@example.com"])
  assert cfg.comment == True
}

pub fn default_branch_ref_only_returns_ref_config_test() {
  let assert Ok(config.RefConfig(url:)) =
    config.parse_default_branch_config(
      "ref = \"https://raw.github.com/org/repo/main/dco.toml\"",
    )
  assert url == "https://raw.github.com/org/repo/main/dco.toml"
}

pub fn default_branch_ref_not_https_errors_test() {
  let assert Error(_) =
    config.parse_default_branch_config(
      "ref = \"http://example.com/config.toml\"",
    )
}

pub fn default_branch_ref_with_other_keys_errors_test() {
  let assert Error(_) =
    config.parse_default_branch_config(
      "ref = \"https://example.com/config.toml\"\ncomment = true",
    )
}

pub fn default_branch_ref_not_string_errors_test() {
  let assert Error(_) = config.parse_default_branch_config("ref = 42")
}

pub fn default_branch_ref_rejected_in_standard_config_test() {
  // config.parse (not parse_default_branch_config) must reject ref
  let assert Error(_) =
    config.parse(
      "ref = \"https://example.com/config.toml\"\nexempt-authors = []",
    )
}

pub fn standard_config_ref_only_also_rejected_test() {
  // Even if ref is the only key, config.parse rejects it
  let assert Error(_) =
    config.parse("ref = \"https://example.com/config.toml\"")
}

// --- config.describe ---

pub fn describe_all_defaults_test() {
  let #(lines, _stdout) =
    take.with_stdout(fn() { config.describe(config.default()) })

  // Every line should be flagged as default
  list.each(lines, fn(line) {
    assert string.contains(line, "(default)")
  })

  assert list.length(lines) == 5
}

pub fn describe_exempt_authors_test() {
  let assert Ok(cfg) =
    config.parse("exempt-authors = [\"joe@example.com\", \"@corp.dev\"]")
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(authors_line) =
    list.find(lines, fn(l) { string.starts_with(l, "exempt-authors:") })
  assert string.contains(authors_line, "joe@example.com")
  assert string.contains(authors_line, "@corp.dev")
  assert !string.contains(authors_line, "(default)")
}

pub fn describe_bot_policy_well_known_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"well-known\"\ncategories = [\"ci-cd\", \"release\"]",
    )
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(bot_line) =
    list.find(lines, fn(l) { string.starts_with(l, "bot-policy:") })
  assert string.contains(bot_line, "well-known")
  assert string.contains(bot_line, "ci-cd")
  assert string.contains(bot_line, "release")
  assert !string.contains(bot_line, "(default)")
}

pub fn describe_bot_policy_allowlist_shows_logins_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"allowlist\"\nallow = [\"dependabot[bot]\", \"renovate[bot]\"]",
    )
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(bot_line) =
    list.find(lines, fn(l) { string.starts_with(l, "bot-policy:") })
  assert string.contains(bot_line, "dependabot[bot]")
  assert string.contains(bot_line, "renovate[bot]")
}

pub fn describe_trailer_parsing_lenient_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"lenient\"")
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(trailer_line) =
    list.find(lines, fn(l) { string.starts_with(l, "trailer-parsing:") })
  assert string.contains(trailer_line, "lenient")
  assert !string.contains(trailer_line, "(default)")
}

pub fn describe_comment_enabled_test() {
  let assert Ok(cfg) = config.parse("comment = true")
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(comment_line) =
    list.find(lines, fn(l) { string.starts_with(l, "comment:") })
  assert string.contains(comment_line, "true")
  assert !string.contains(comment_line, "(default)")
}

pub fn describe_multiple_aliases_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"bot@noreply.github.com\" = [\"support@github.com\"]\n\"other@noreply.github.com\" = [\"ops@company.com\", \"admin@company.com\"]",
    )
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  let assert Ok(alias_line) =
    list.find(lines, fn(l) { string.starts_with(l, "alias-signoffs:") })
  assert string.contains(alias_line, "bot@noreply.github.com")
  assert string.contains(alias_line, "support@github.com")
  assert string.contains(alias_line, "other@noreply.github.com")
  assert string.contains(alias_line, "ops@company.com")
  assert string.contains(alias_line, "admin@company.com")
  assert !string.contains(alias_line, "(default)")
}
