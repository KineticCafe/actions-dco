import dco_check/config.{
  AiAgents, AiIgnore, AiReject, AiSignoffReject, AiSignoffRequireHuman, AiWarn,
  AllBots, CiCd, DependencyUpdaters, Exemptions, Lenient, NoBots, Release,
  Strict, WellKnownBots,
}
import dco_check/error
import dco_check/internal/ai_agents
import gleam/dict
import gleam/list
import gleam/string
import take

fn invalid_key(toml: String) -> List(String) {
  let assert Error(error.ConfigInvalidValue(key:, ..)) = config.parse(toml)
  key
}

fn invalid_message(toml: String) -> String {
  let assert Error(error.ConfigInvalidValue(message:, ..)) = config.parse(toml)
  message
}

fn warnings(toml: String) -> List(String) {
  let assert Ok(cfg) = config.parse(toml)
  cfg.warnings
}

fn has_warning(toml: String, fragment: String) -> Bool {
  list.any(warnings(toml), fn(w) { string.contains(w, fragment) })
}

// --- empty config ---

pub fn parse_empty_string_returns_default_test() {
  let assert Ok(cfg) = config.parse("")
  assert cfg == config.default()
}

pub fn parse_whitespace_only_returns_default_test() {
  let assert Ok(cfg) = config.parse("  \n\n  ")
  assert cfg == config.default()
}

pub fn parse_comments_only_returns_default_test() {
  let assert Ok(cfg) = config.parse("# nothing configured yet\n")
  assert cfg == config.default()
}

// --- type mismatches are always errors ---

pub fn type_mismatches_are_errors_test() {
  assert invalid_key("comment = \"yes\"") == ["comment"]
  assert invalid_key("trailer-parsing = 1") == ["trailer-parsing"]
  assert invalid_key("bots = 1") == ["bots"]
  assert invalid_key("[bots]\ncategories = \"ci-cd\"") == ["bots", "categories"]
  assert invalid_key("[bots]\ncategories = [1]") == ["bots", "categories"]
  assert invalid_key("[bots]\nallow = \"x[bot]\"") == ["bots", "allow"]
  assert invalid_key("exempt-authors = \"joe@example.com\"")
    == ["exempt-authors"]
  assert invalid_key("ai = 1") == ["ai"]
  assert invalid_key("alias-signoffs = 1") == ["alias-signoffs"]
}

pub fn invalid_value_error_names_the_key_test() {
  let assert Error(err) = config.parse("[bots]\nallow = [1]")
  assert error.describe_error(err)
    == "Invalid config: bots.allow: expected an array of strings, but item 1 is an integer"
  let assert Error(err) = config.parse("comment = \"yes\"")
  assert error.describe_error(err)
    == "Invalid config: comment: expected a boolean, got a string"
}

pub fn default_branch_config_rejects_type_mismatches_test() {
  let assert Error(error.ConfigInvalidValue(..)) =
    config.parse_default_branch_config("[bots]\nallow = [1]")
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

pub fn parse_exempt_authors_rejects_non_strings_test() {
  let assert Error(err) =
    config.parse("exempt-authors = [\"joe@example.com\", false]")
  assert err
    == error.ConfigInvalidValue(
      key: ["exempt-authors"],
      message: "expected an array of strings, but item 2 is a boolean",
    )
}

pub fn parse_exempt_authors_rejects_non_email_shapes_test() {
  assert invalid_key("exempt-authors = [\"joe\"]") == ["exempt-authors"]
  assert invalid_key("exempt-authors = [\"example.com\"]") == ["exempt-authors"]
  assert invalid_key("exempt-authors = [\"@\"]") == ["exempt-authors"]
  assert invalid_key("exempt-authors = [\"@localhost\"]") == ["exempt-authors"]
  assert invalid_key("exempt-authors = [\"joe@\"]") == ["exempt-authors"]
  assert string.contains(
    invalid_message("exempt-authors = [\"joe\"]"),
    "\"joe\" is not an email address or an @domain pattern",
  )
}

pub fn parse_exempt_authors_accepts_bot_noreply_address_test() {
  let assert Ok(cfg) =
    config.parse(
      "exempt-authors = [\"49699333+dependabot[bot]@users.noreply.github.com\"]",
    )
  assert cfg.exempt_authors.exact
    == ["49699333+dependabot[bot]@users.noreply.github.com"]
}

pub fn parse_exempt_authors_warns_on_noreply_test() {
  let toml =
    "exempt-authors = [\"@users.noreply.github.com\", \"noreply@example.com\", \"me@no-reply.example.com\", \"joe@example.com\"]"
  let assert Ok(cfg) = config.parse(toml)
  // Accepted in 4.0, with a warning for each no-reply entry.
  assert list.length(cfg.exempt_authors.exact) == 3
  assert cfg.exempt_authors.ends_with == ["@users.noreply.github.com"]
  assert list.length(cfg.warnings) == 3
  assert list.all(cfg.warnings, fn(w) { string.contains(w, "4.1") })
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

// --- trailer-parsing ---

pub fn parse_trailer_parsing_strict_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"strict\"")
  assert cfg.trailer_parsing == Strict
}

pub fn parse_trailer_parsing_lenient_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"lenient\"")
  assert cfg.trailer_parsing == Lenient
}

pub fn parse_trailer_parsing_unknown_warns_and_uses_strict_test() {
  let assert Ok(cfg) = config.parse("trailer-parsing = \"bogus\"")
  assert cfg.trailer_parsing == Strict
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "\"bogus\"")
  assert string.contains(warning, "4.1")
}

// --- bots.policy ---

pub fn parse_bot_policy_all_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"all\"")
  assert cfg.bots == AllBots
  assert cfg.warnings == []
}

pub fn parse_bot_policy_none_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"none\"")
  assert cfg.bots == NoBots
}

pub fn default_bot_policy_is_well_known_all_categories_test() {
  assert config.default().bots
    == WellKnownBots(categories: [DependencyUpdaters, CiCd, Release])
  let assert Ok(cfg) = config.parse("comment = true")
  assert cfg.bots == config.default().bots
  assert cfg.warnings == []
}

pub fn parse_bot_policy_allowlist_is_none_with_warning_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"allowlist\"\nallow = [\"dependabot[bot]\", \"renovate[bot]\"]",
    )
  assert cfg.bots == NoBots
  assert cfg.bot_allow == ["dependabot[bot]", "renovate[bot]"]
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "deprecated")
  assert string.contains(warning, "4.1")
  assert string.contains(warning, "\"none\"")
}

pub fn parse_bot_policy_unknown_is_none_with_warning_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"everything\"")
  assert cfg.bots == NoBots
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "\"everything\"")
  assert string.contains(warning, "using \"none\"")
  assert string.contains(warning, "4.1")
}

pub fn parse_bot_policy_not_a_string_is_none_with_warning_test() {
  let assert Ok(cfg) = config.parse("[bots]\npolicy = true")
  assert cfg.bots == NoBots
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "a boolean, not a string")
  assert string.contains(warning, "using \"none\"")
  assert string.contains(warning, "4.1")
}

// --- bots.categories ---

pub fn parse_well_known_specific_categories_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"well-known\"\ncategories = [\"ci-cd\", \"release\"]",
    )
  assert cfg.bots == WellKnownBots(categories: [CiCd, Release])
}

pub fn parse_categories_without_policy_test() {
  let assert Ok(cfg) = config.parse("[bots]\ncategories = [\"ci-cd\"]")
  assert cfg.bots == WellKnownBots(categories: [CiCd])
}

pub fn parse_categories_empty_is_an_error_test() {
  assert invalid_key("[bots]\npolicy = \"well-known\"\ncategories = []")
    == ["bots", "categories"]
  assert string.contains(invalid_message("[bots]\ncategories = []"), "is empty")
}

pub fn parse_categories_unknown_names_are_dropped_with_warning_test() {
  let assert Ok(cfg) =
    config.parse("[bots]\ncategories = [\"ci-cd\", \"made-up\"]")
  assert cfg.bots == WellKnownBots(categories: [CiCd])
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "\"made-up\"")
  assert string.contains(warning, "4.1")
}

pub fn parse_categories_with_no_known_names_is_an_error_test() {
  // Dropping the unknown name would leave nothing, which would exempt no bots.
  assert invalid_key("[bots]\ncategories = [\"dependabot\"]")
    == ["bots", "categories"]
  assert string.contains(
    invalid_message("[bots]\ncategories = [\"dependabot\", \"bots\"]"),
    "names no known category",
  )
}

pub fn parse_categories_rejects_ai_test() {
  assert invalid_key("[bots]\ncategories = [\"ci-cd\", \"ai\"]")
    == ["bots", "categories"]
  assert string.contains(
    invalid_message("[bots]\ncategories = [\"ai\"]"),
    "bots.exclude-categories",
  )
}

pub fn parse_categories_not_resolved_for_other_policies_test() {
  let assert Ok(cfg) =
    config.parse("[bots]\npolicy = \"none\"\ncategories = [\"made-up\"]")
  assert cfg.bots == NoBots
  assert cfg.warnings == []
}

pub fn parse_categories_type_checked_under_every_policy_test() {
  list.each(["all", "none", "allowlist", "bogus"], fn(policy) {
    assert invalid_key(
        "[bots]\npolicy = \"" <> policy <> "\"\ncategories = \"ci-cd\"",
      )
      == ["bots", "categories"]
    assert invalid_key(
        "[bots]\npolicy = \"" <> policy <> "\"\ncategories = [1]",
      )
      == ["bots", "categories"]
  })
}

// --- bots.exclude-categories ---

pub fn parse_exclude_categories_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"all\"\nexclude-categories = [\"ai\", \"release\"]",
    )
  assert cfg.bots == AllBots
  assert cfg.bot_exclude == [AiAgents, Release]
}

pub fn parse_exclude_categories_defaults_to_none_test() {
  assert config.default().bot_exclude == []
}

pub fn parse_exclude_categories_is_strict_test() {
  assert invalid_key("[bots]\nexclude-categories = [\"robots\"]")
    == ["bots", "exclude-categories"]
  assert invalid_key("[bots]\nexclude-categories = \"ai\"")
    == ["bots", "exclude-categories"]
  assert invalid_key("[bots]\nexclude-categories = [true]")
    == ["bots", "exclude-categories"]
}

// --- bots.allow ---

pub fn parse_bot_allow_under_every_policy_test() {
  list.each(["all", "none", "well-known"], fn(policy) {
    let assert Ok(cfg) =
      config.parse(
        "[bots]\npolicy = \"" <> policy <> "\"\nallow = [\"mybot[bot]\"]",
      )
    assert cfg.bot_allow == ["mybot[bot]"]
  })
}

pub fn parse_bot_allow_rejects_non_string_items_test() {
  let assert Error(err) = config.parse("[bots]\nallow = [\"mybot[bot]\", 3]")
  assert err
    == error.ConfigInvalidValue(
      key: ["bots", "allow"],
      message: "expected an array of strings, but item 2 is an integer",
    )
}

pub fn parse_bot_allow_warns_on_email_addresses_test() {
  let assert Ok(cfg) =
    config.parse("[bots]\nallow = [\"bot@example.com\", \"mybot[bot]\"]")
  assert cfg.bot_allow == ["bot@example.com", "mybot[bot]"]
  let assert [warning] = cfg.warnings
  assert string.contains(warning, "\"bot@example.com\"")
  assert string.contains(warning, "4.1")
}

// --- removed and unknown keys ---

pub fn removed_ai_detection_key_is_an_error_test() {
  assert invalid_key("[bots]\nai-detection = true") == ["bots", "ai-detection"]
}

pub fn unknown_keys_are_ignored_with_warnings_test() {
  let toml =
    "bogus = 1\n[bot]\npolicy = \"all\"\n[bots]\npolcy = \"all\"\n[bots.ai]\nrequire-signoff = true\n[alias-signoffs]\nwith-mailmap = true"
  let assert Ok(cfg) = config.parse(toml)
  assert cfg.bots == config.default().bots
  assert has_warning(toml, "Unknown configuration key bogus ")
  assert has_warning(toml, "Unknown configuration key bot ")
  assert has_warning(toml, "Unknown configuration key bots.polcy ")
  assert has_warning(toml, "Unknown configuration key bots.ai ")
  assert has_warning(
    toml,
    "Unknown configuration key alias-signoffs.with-mailmap ",
  )
  assert list.length(cfg.warnings) == 5
}

// --- [ai] ---

pub fn parse_ai_defaults_test() {
  let assert Ok(cfg) = config.parse("")
  assert cfg.ai
    == config.AiConfig(
      signed_off_by: AiSignoffReject,
      co_authored_by: AiIgnore,
      trace_detection: AiIgnore,
      extra_agent_emails: [],
      ignore_agents: [],
    )
}

pub fn parse_ai_test() {
  let assert Ok(cfg) =
    config.parse(
      "[ai]\nsigned-off-by = \"require-human\"\nco-authored-by = \"reject\"\ntrace-detection = \"warn\"\nextra-agent-emails = [\"Agent@Example.com\"]\nignore-agents = [\"openhands\"]",
    )
  assert cfg.ai
    == config.AiConfig(
      signed_off_by: AiSignoffRequireHuman,
      co_authored_by: AiReject,
      trace_detection: AiWarn,
      extra_agent_emails: ["agent@example.com"],
      ignore_agents: ["openhands"],
    )
  assert cfg.warnings == []
}

pub fn parse_ai_enums_are_strict_test() {
  assert invalid_key("[ai]\nsigned-off-by = \"never\"")
    == ["ai", "signed-off-by"]
  assert invalid_key("[ai]\nsigned-off-by = true") == ["ai", "signed-off-by"]
  assert invalid_key("[ai]\nco-authored-by = \"allow\"")
    == ["ai", "co-authored-by"]
  assert invalid_key("[ai]\ntrace-detection = false")
    == ["ai", "trace-detection"]
  assert string.contains(
    invalid_message("[ai]\nco-authored-by = \"allow\""),
    "\"ignore\", \"warn\", \"reject\"",
  )
}

pub fn parse_ai_rejects_unknown_keys_test() {
  assert invalid_key("[ai]\nrequire-signoff = true")
    == ["ai", "require-signoff"]
  assert invalid_key("[ai]\ntrace-detecton = \"reject\"")
    == ["ai", "trace-detecton"]
}

pub fn parse_extra_agent_emails_is_strict_test() {
  let assert Error(err) =
    config.parse("[ai]\nextra-agent-emails = [\"agent@example.com\", true]")
  assert err
    == error.ConfigInvalidValue(
      key: ["ai", "extra-agent-emails"],
      message: "expected an array of strings, but item 2 is a boolean",
    )
  assert invalid_key("[ai]\nextra-agent-emails = [\"agent\"]")
    == ["ai", "extra-agent-emails"]
}

pub fn parse_ignore_agents_resolves_every_reference_form_test() {
  let assert Ok(cfg) =
    config.parse(
      "[ai]\nignore-agents = [\"github-copilot\", \"copilot-swe-agent[bot]\", \"167198135+copilot[bot]@users.noreply.github.com\", \"OpenHands@All-Hands.dev\"]",
    )
  assert cfg.ai.ignore_agents == ["github-copilot", "openhands"]
}

pub fn parse_ignore_agents_rejects_unknown_agents_test() {
  assert invalid_key("[ai]\nignore-agents = [\"skynet\"]")
    == ["ai", "ignore-agents"]
}

pub fn parse_ignore_agents_never_resolves_extra_agent_emails_test() {
  assert invalid_key(
      "[ai]\nextra-agent-emails = [\"agent@example.com\"]\nignore-agents = [\"agent@example.com\"]",
    )
    == ["ai", "ignore-agents"]
}

pub fn ai_registry_includes_extra_agent_emails_test() {
  let assert Ok(cfg) =
    config.parse("[ai]\nextra-agent-emails = [\"agent@example.com\"]")
  let registry = config.ai_registry(cfg)

  assert ai_agents.match_email(registry:, email: "agent@example.com")
    == Ok(ai_agents.configured_agent)
  assert ai_agents.match_email(registry:, email: "noreply@anthropic.com")
    == Ok("Claude")
}

pub fn ai_relaxed_registry_drops_ignore_agents_test() {
  let assert Ok(cfg) = config.parse("[ai]\nignore-agents = [\"claude\"]")
  let full = config.ai_registry(cfg)
  let relaxed = config.ai_relaxed_registry(cfg)

  assert ai_agents.match_email(registry: full, email: "noreply@anthropic.com")
    == Ok("Claude")
  assert ai_agents.match_email(
      registry: relaxed,
      email: "noreply@anthropic.com",
    )
    == Error(Nil)
  assert ai_agents.match_login(registry: relaxed, login: "claude[bot]")
    == Error(Nil)
  assert ai_agents.match_email(registry: relaxed, email: "copilot@github.com")
    == Ok("GitHub Copilot")
}

// --- alias-signoffs.aliases ---

pub fn parse_aliases_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"49699333+dependabot[bot]@users.noreply.github.com\" = [\"support@github.com\"]",
    )
  assert dict.get(
      cfg.aliases,
      "49699333+dependabot[bot]@users.noreply.github.com",
    )
    == Ok(["support@github.com"])
  assert cfg.warnings == []
}

pub fn parse_aliases_lowercases_keys_and_values_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"BOT@Example.COM\" = [\"Support@GitHub.COM\"]",
    )
  assert dict.get(cfg.aliases, "bot@example.com") == Ok(["support@github.com"])
}

pub fn parse_aliases_rejects_non_string_items_test() {
  let assert Error(err) =
    config.parse(
      "[alias-signoffs.aliases]\n\"bot@example.com\" = [\"support@github.com\", 7]",
    )
  assert err
    == error.ConfigInvalidValue(
      key: ["alias-signoffs", "aliases", "bot@example.com"],
      message: "expected an array of strings, but item 2 is an integer",
    )
}

pub fn parse_aliases_rejects_non_array_value_test() {
  let assert Error(err) =
    config.parse(
      "[alias-signoffs.aliases]\n\"bot@example.com\" = \"support@github.com\"",
    )
  assert err
    == error.ConfigInvalidValue(
      key: ["alias-signoffs", "aliases", "bot@example.com"],
      message: "expected an array of strings, got a string",
    )
}

pub fn parse_aliases_rejects_non_table_test() {
  assert invalid_key("[alias-signoffs]\naliases = [\"x\"]")
    == ["alias-signoffs", "aliases"]
}

pub fn parse_aliases_drops_non_email_entries_with_warnings_test() {
  let toml =
    "[alias-signoffs.aliases]\n\"not-an-email\" = [\"a@example.com\"]\n\"me@example.com\" = [\"bogus\", \"me@work.example\"]\n\"x@example.com\" = [\"nope\"]"
  let assert Ok(cfg) = config.parse(toml)

  assert dict.to_list(cfg.aliases) == [#("me@example.com", ["me@work.example"])]
  assert list.length(cfg.warnings) == 3
  assert has_warning(toml, "\"not-an-email\"")
  assert has_warning(toml, "\"bogus\"")
  assert has_warning(toml, "\"nope\"")
}

pub fn parse_aliases_allow_noreply_values_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"123+me@users.noreply.github.com\" = [\"noreply@example.com\"]",
    )
  assert cfg.warnings == []
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

fn describe_line(cfg: config.Config, prefix: String) -> String {
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })
  let assert Ok(line) =
    list.find(lines, fn(l) { string.starts_with(l, prefix <> ":") })
  line
}

pub fn describe_all_defaults_test() {
  let #(lines, _stdout) =
    take.with_stdout(fn() { config.describe(config.default()) })

  list.each(lines, fn(line) {
    assert string.contains(line, "(default)")
  })
  assert list.length(lines) == 12
  assert describe_line(config.default(), "bots.policy")
    == "bots.policy: well-known (all categories) (default)"
}

pub fn describe_exempt_authors_test() {
  let assert Ok(cfg) =
    config.parse("exempt-authors = [\"joe@example.com\", \"@corp.dev\"]")
  let line = describe_line(cfg, "exempt-authors")
  assert string.contains(line, "joe@example.com")
  assert string.contains(line, "@corp.dev")
  assert !string.contains(line, "(default)")
}

pub fn describe_bot_policy_well_known_test() {
  let assert Ok(cfg) =
    config.parse("[bots]\ncategories = [\"ci-cd\", \"release\"]")
  assert describe_line(cfg, "bots.policy")
    == "bots.policy: well-known (ci-cd, release)"
}

pub fn describe_bots_lists_test() {
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"none\"\nallow = [\"dependabot[bot]\"]\nexclude-categories = [\"ai\"]",
    )
  assert describe_line(cfg, "bots.allow") == "bots.allow: dependabot[bot]"
  assert describe_line(cfg, "bots.exclude-categories")
    == "bots.exclude-categories: ai"
}

pub fn describe_ai_test() {
  let assert Ok(cfg) =
    config.parse(
      "[ai]\nsigned-off-by = \"require-human\"\nco-authored-by = \"warn\"\ntrace-detection = \"reject\"\nextra-agent-emails = [\"a@example.com\", \"b@example.com\"]\nignore-agents = [\"openhands\"]",
    )
  let #(lines, _stdout) = take.with_stdout(fn() { config.describe(cfg) })

  assert describe_line(cfg, "ai.signed-off-by")
    == "ai.signed-off-by: require-human"
  assert describe_line(cfg, "ai.co-authored-by") == "ai.co-authored-by: warn"
  assert describe_line(cfg, "ai.trace-detection")
    == "ai.trace-detection: reject"
  assert describe_line(cfg, "ai.ignore-agents") == "ai.ignore-agents: openhands"
  assert describe_line(cfg, "ai.extra-agent-emails")
    == "ai.extra-agent-emails: 2 addresses"
  // The log is public: report a count, never the addresses.
  assert !list.any(lines, fn(l) { string.contains(l, "a@example.com") })
}

pub fn describe_ai_defaults_test() {
  let cfg = config.default()
  assert describe_line(cfg, "ai.signed-off-by")
    == "ai.signed-off-by: reject (default)"
  assert describe_line(cfg, "ai.co-authored-by")
    == "ai.co-authored-by: ignore (default)"
  assert describe_line(cfg, "ai.extra-agent-emails")
    == "ai.extra-agent-emails: none (default)"
}

pub fn describe_extra_agent_emails_singular_test() {
  let assert Ok(cfg) =
    config.parse("[ai]\nextra-agent-emails = [\"a@example.com\"]")
  assert describe_line(cfg, "ai.extra-agent-emails")
    == "ai.extra-agent-emails: 1 address"
}

pub fn describe_trailer_parsing_and_comment_test() {
  let assert Ok(cfg) =
    config.parse("trailer-parsing = \"lenient\"\ncomment = true")
  assert describe_line(cfg, "trailer-parsing") == "trailer-parsing: lenient"
  assert describe_line(cfg, "comment") == "comment: true"
}

pub fn describe_multiple_aliases_test() {
  let assert Ok(cfg) =
    config.parse(
      "[alias-signoffs.aliases]\n\"bot@noreply.github.com\" = [\"support@github.com\"]\n\"other@noreply.github.com\" = [\"ops@company.com\", \"admin@company.com\"]",
    )
  let line = describe_line(cfg, "alias-signoffs")
  assert string.contains(line, "bot@noreply.github.com")
  assert string.contains(line, "support@github.com")
  assert string.contains(line, "other@noreply.github.com")
  assert string.contains(line, "ops@company.com")
  assert string.contains(line, "admin@company.com")
  assert !string.contains(line, "(default)")
}
