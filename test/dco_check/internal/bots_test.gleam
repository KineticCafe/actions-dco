import dco_check/config.{
  AiAgents, AllBots, CiCd, DependencyUpdaters, NoBots, Release, WellKnownBots,
}
import dco_check/internal/ai_agents
import dco_check/internal/bots

fn registry() -> ai_agents.Registry {
  ai_agents.effective(extra_agent_emails: [])
}

const all_categories =
  WellKnownBots(categories: [DependencyUpdaters, CiCd, Release])

/// Exemption with no excluded categories.
fn exempt(
  login: String,
  policy: config.BotPolicy,
  allow: List(String),
) -> Bool {
  exempt_excluding(login, policy, allow, [])
}

fn exempt_excluding(
  login: String,
  policy: config.BotPolicy,
  allow: List(String),
  exclude: List(config.BotCategory),
) -> Bool {
  bots.is_bot_exempt(login:, policy:, allow:, exclude:, registry: registry())
}

// --- AllBots ---

pub fn all_bots_exempts_any_login_test() {
  assert exempt("random[bot]", AllBots, []) == True
}

// --- NoBots ---

pub fn no_bots_rejects_all_test() {
  assert exempt("dependabot[bot]", NoBots, []) == False
}

// --- WellKnownBots ---

pub fn well_known_all_categories_test() {
  assert exempt("dependabot[bot]", all_categories, []) == True
  assert exempt("github-actions[bot]", all_categories, []) == True
  assert exempt("release-please[bot]", all_categories, []) == True
}

pub fn well_known_specific_category_test() {
  let policy = WellKnownBots(categories: [DependencyUpdaters])
  assert exempt("dependabot[bot]", policy, []) == True
  assert exempt("github-actions[bot]", policy, []) == False
}

pub fn well_known_rejects_unknown_bot_test() {
  assert exempt("my-custom[bot]", all_categories, []) == False
}

pub fn well_known_never_exempts_ai_bots_test() {
  assert exempt("claude[bot]", all_categories, []) == False
}

pub fn well_known_case_insensitive_test() {
  assert exempt(
      "Dependabot[bot]",
      WellKnownBots(categories: [DependencyUpdaters]),
      [],
    )
    == True
}

pub fn well_known_release_category_test() {
  let policy = WellKnownBots(categories: [Release])
  assert exempt("semantic-release[bot]", policy, []) == True
  assert exempt("release-please[bot]", policy, []) == True
}

// --- allow list applies under every policy ---

pub fn allow_exempts_under_none_test() {
  assert exempt("mybot[bot]", NoBots, ["mybot[bot]"]) == True
}

pub fn allow_rejects_unlisted_under_none_test() {
  assert exempt("renovate[bot]", NoBots, ["dependabot[bot]"]) == False
}

pub fn allow_adds_to_well_known_test() {
  let policy = WellKnownBots(categories: [DependencyUpdaters])
  let allow = ["mybot[bot]"]
  assert exempt("mybot[bot]", policy, allow) == True
  assert exempt("dependabot[bot]", policy, allow) == True
  assert exempt("other[bot]", policy, allow) == False
}

pub fn allow_case_insensitive_test() {
  assert exempt("Dependabot[bot]", NoBots, ["DEPENDABOT[bot]"]) == True
}

// --- bots.exclude-categories ---

pub fn ai_bot_exempt_under_all_without_exclusion_test() {
  assert exempt("claude[bot]", AllBots, []) == True
}

pub fn excluding_ai_denies_ai_bots_under_all_test() {
  assert exempt_excluding("claude[bot]", AllBots, [], [AiAgents]) == False
  assert exempt_excluding("Copilot", AllBots, [], [AiAgents]) == False
  assert exempt_excluding("random[bot]", AllBots, [], [AiAgents]) == True
}

pub fn excluding_a_well_known_category_test() {
  assert exempt_excluding("release-please[bot]", AllBots, [], [Release])
    == False
  assert exempt_excluding("release-please[bot]", all_categories, [], [Release])
    == False
  assert exempt_excluding("dependabot[bot]", all_categories, [], [Release])
    == True
}

pub fn allow_list_beats_exclusion_test() {
  assert exempt_excluding("claude[bot]", AllBots, ["claude[bot]"], [AiAgents])
    == True
  assert exempt_excluding("Claude[bot]", NoBots, ["claude[bot]"], [AiAgents])
    == True
}

pub fn excluded_category_test() {
  assert bots.excluded_category(
      login: "cursor[bot]",
      exclude: [Release, AiAgents],
      registry: registry(),
    )
    == Ok(AiAgents)
  assert bots.excluded_category(
      login: "dependabot[bot]",
      exclude: [Release, AiAgents],
      registry: registry(),
    )
    == Error(Nil)
}

pub fn extra_agent_emails_do_not_affect_bot_logins_test() {
  // Bot exclusion looks only at the GitHub login; extra agent emails are for trailers.
  let registry =
    ai_agents.effective(extra_agent_emails: ["in-house@example.com"])
  assert bots.is_bot_exempt(
      login: "in-house-ai[bot]",
      policy: AllBots,
      allow: [],
      exclude: [AiAgents],
      registry:,
    )
    == True
}

pub fn is_ai_agent_test() {
  assert bots.is_ai_agent(
    login: "devin-ai-integration[bot]",
    registry: registry(),
  )
  assert !bots.is_ai_agent(login: "dependabot[bot]", registry: registry())
}
