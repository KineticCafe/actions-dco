import dco_check/internal/ai_agents
import gleam/list
import gleam/string

fn built_in() -> ai_agents.Registry {
  ai_agents.effective(extra_agent_emails: [])
}

fn all_emails() -> List(String) {
  list.flat_map(ai_agents.agents, fn(agent) { agent.emails })
}

fn all_logins() -> List(String) {
  list.flat_map(ai_agents.agents, fn(agent) { agent.logins })
}

// --- registry invariants ---

/// Mechanical bots must never be in the registry; see the module doc.
pub fn no_mechanical_bots_test() {
  let forbidden = ["dependabot", "renovate"]

  list.each(list.append(all_emails(), all_logins()), fn(value) {
    assert !list.any(forbidden, fn(bot) { string.contains(value, bot) })
  })

  list.each(ai_agents.agents, fn(agent) {
    let name = string.lowercase(agent.name)
    assert !list.any(forbidden, fn(bot) { string.contains(name, bot) })
  })
}

pub fn mechanical_bot_identities_do_not_match_test() {
  let registry = built_in()

  assert ai_agents.match_login(registry:, login: "dependabot[bot]")
    == Error(Nil)
  assert ai_agents.match_login(registry:, login: "renovate[bot]") == Error(Nil)
  assert ai_agents.match_email(
      registry:,
      email: "49699333+dependabot[bot]@users.noreply.github.com",
    )
    == Error(Nil)
  assert ai_agents.match_email(
      registry:,
      email: "29139614+renovate[bot]@users.noreply.github.com",
    )
    == Error(Nil)
  assert ai_agents.match_email(registry:, email: "support@github.com")
    == Error(Nil)
}

pub fn entries_are_normalized_test() {
  list.each(list.append(all_emails(), all_logins()), fn(value) {
    assert value == string.lowercase(string.trim(value))
    assert value != ""
  })
}

pub fn emails_look_like_emails_test() {
  list.each(all_emails(), fn(email) {
    assert string.contains(email, "@")
    assert !string.contains(email, " ")
  })
}

pub fn entries_are_unique_test() {
  assert list.unique(all_emails()) == all_emails()
  assert list.unique(all_logins()) == all_logins()
}

pub fn every_agent_has_an_identity_test() {
  list.each(ai_agents.agents, fn(agent) {
    assert agent.emails != [] || agent.logins != []
  })
}

// --- agent keys ---

pub fn agent_keys_are_unique_test() {
  let keys = list.map(ai_agents.agents, fn(agent) { agent.key })
  assert list.unique(keys) == keys
}

pub fn agent_keys_are_slugs_test() {
  list.each(ai_agents.agents, fn(agent) {
    assert agent.key != ""
    assert !string.starts_with(agent.key, "-")
    assert !string.ends_with(agent.key, "-")
    assert string.to_graphemes(agent.key)
      |> list.all(fn(ch) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789-", ch)
      })
  })
}

pub fn agent_keys_do_not_collide_with_identities_test() {
  // A key that is also some agent's email or login would make resolve_key ambiguous.
  let identities = list.append(all_emails(), all_logins())
  list.each(ai_agents.agents, fn(agent) {
    assert !list.contains(identities, agent.key)
      || list.contains(list.append(agent.emails, agent.logins), agent.key)
  })
}

pub fn resolve_key_test() {
  assert ai_agents.resolve_key("claude") == Ok("claude")
  assert ai_agents.resolve_key("GitHub-Copilot") == Ok("github-copilot")
  assert ai_agents.resolve_key("copilot-swe-agent[bot]") == Ok("github-copilot")
  assert ai_agents.resolve_key(
      "167198135+copilot[bot]@users.noreply.github.com",
    )
    == Ok("github-copilot")
  assert ai_agents.resolve_key("openhands@all-hands.dev") == Ok("openhands")
  assert ai_agents.resolve_key("Claude") == Ok("claude")
  assert ai_agents.resolve_key("dependabot[bot]") == Error(Nil)
  assert ai_agents.resolve_key("alice@example.com") == Error(Nil)
}

pub fn without_drops_only_the_named_agents_test() {
  let registry =
    ai_agents.effective(extra_agent_emails: ["agent@example.com"])
    |> ai_agents.without(keys: ["claude", "github-copilot"])

  assert ai_agents.match_email(registry:, email: "noreply@anthropic.com")
    == Error(Nil)
  assert ai_agents.match_login(registry:, login: "claude[bot]") == Error(Nil)
  assert ai_agents.match_login(registry:, login: "Copilot") == Error(Nil)
  assert ai_agents.match_email(registry:, email: "cursoragent@cursor.com")
    == Ok("Cursor")
  assert ai_agents.match_email(registry:, email: "agent@example.com")
    == Ok(ai_agents.configured_agent)
}

// --- match_email / match_login ---

pub fn matches_built_in_email_test() {
  assert ai_agents.match_email(
      registry: built_in(),
      email: "noreply@anthropic.com",
    )
    == Ok("Claude")
}

pub fn email_match_is_case_insensitive_test() {
  assert ai_agents.match_email(
      registry: built_in(),
      email: "198982749+Copilot@users.noreply.github.com",
    )
    == Ok("GitHub Copilot")
}

pub fn matches_built_in_login_test() {
  assert ai_agents.match_login(
      registry: built_in(),
      login: "devin-ai-integration[bot]",
    )
    == Ok("Devin")
}

pub fn login_match_is_case_insensitive_test() {
  assert ai_agents.match_login(registry: built_in(), login: "Copilot")
    == Ok("GitHub Copilot")
}

pub fn unknown_email_does_not_match_test() {
  assert ai_agents.match_email(registry: built_in(), email: "alice@example.com")
    == Error(Nil)
}

// --- match_identity ---

pub fn matches_trailer_identity_by_email_test() {
  assert ai_agents.match_identity(
      registry: built_in(),
      value: "Claude Opus 4.6 (1M context) <noreply@anthropic.com>",
    )
    == Ok("Claude")
}

pub fn name_alone_never_matches_test() {
  assert ai_agents.match_identity(registry: built_in(), value: "Claude")
    == Error(Nil)
  assert ai_agents.match_identity(registry: built_in(), value: "GitHub Copilot")
    == Error(Nil)
}

pub fn agent_name_with_human_email_does_not_match_test() {
  assert ai_agents.match_identity(
      registry: built_in(),
      value: "Devin Smith <devin@example.com>",
    )
    == Error(Nil)
  assert ai_agents.match_identity(
      registry: built_in(),
      value: "Cursor <cursor.fan@example.com>",
    )
    == Error(Nil)
}

pub fn no_substring_matching_test() {
  // The removed substring detector would have flagged "gpt" in this email.
  assert ai_agents.match_identity(
      registry: built_in(),
      value: "Egypt Jones <egypt@example.com>",
    )
    == Error(Nil)
  assert ai_agents.match_email(
      registry: built_in(),
      email: "not-noreply@anthropic.com",
    )
    == Error(Nil)
}

pub fn malformed_identity_does_not_match_test() {
  assert ai_agents.match_identity(
      registry: built_in(),
      value: "noreply@anthropic.com",
    )
    == Error(Nil)
}

pub fn is_built_in_email_test() {
  assert ai_agents.is_built_in_email("noreply@anthropic.com")
  assert ai_agents.is_built_in_email("CursorAgent@Cursor.com")
  assert !ai_agents.is_built_in_email("alice@example.com")
  assert !ai_agents.is_built_in_email("")
}

pub fn is_built_in_email_ignores_extra_agent_emails_test() {
  // Extra agent emails need a Registry; the display helper only knows the built-in list.
  let registry = ai_agents.effective(extra_agent_emails: ["house@example.com"])
  assert ai_agents.match_email(registry:, email: "house@example.com")
    == Ok(ai_agents.configured_agent)
  assert !ai_agents.is_built_in_email("house@example.com")
}

// --- extra agent emails ---

pub fn extra_agent_email_matches_test() {
  let registry =
    ai_agents.effective(extra_agent_emails: [" Agent@Example.COM "])

  assert ai_agents.match_identity(registry:, value: "Bot <agent@example.com>")
    == Ok(ai_agents.configured_agent)
}

pub fn extra_agent_emails_keep_built_in_names_test() {
  let registry =
    ai_agents.effective(extra_agent_emails: ["noreply@anthropic.com"])

  assert ai_agents.match_email(registry:, email: "noreply@anthropic.com")
    == Ok("Claude")
}

pub fn empty_extra_agent_emails_are_ignored_test() {
  let registry = ai_agents.effective(extra_agent_emails: ["", "  "])

  assert ai_agents.match_email(registry:, email: "") == Error(Nil)
}

pub fn extra_agent_emails_add_to_built_in_entries_test() {
  let registry = ai_agents.effective(extra_agent_emails: ["agent@example.com"])

  assert ai_agents.match_email(registry:, email: "noreply@anthropic.com")
    == Ok("Claude")
  // Built-in bot logins are still known.
  assert ai_agents.match_login(registry:, login: "cursor[bot]") == Ok("Cursor")
}
