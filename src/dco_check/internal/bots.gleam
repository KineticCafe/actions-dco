//// Well-known bot registry.
////
//// Bot categories group bots by purpose.

import dco_check/config
import dco_check/internal/ai_agents
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// Well-known bots grouped by category.
pub const dependency_updaters = [
  "dependabot[bot]",
  "renovate[bot]",
  "snyk-bot[bot]",
]

pub const ci_cd = ["github-actions[bot]"]

pub const release = ["semantic-release[bot]", "release-please[bot]"]

/// Resolve whether a bot login is exempt from sign-offs, in order:
///
/// 1. A login in `allow` is exempt under every policy (explicit intent, AI bots included).
/// 2. A login in an `exclude` category is not exempt. For `AiAgents`, that is any bot login
///    in the AI agent registry.
/// 3. Otherwise the policy decides.
///
/// Comparisons are case-insensitive.
pub fn is_bot_exempt(
  login login: String,
  policy policy: config.BotPolicy,
  allow allow: List(String),
  exclude exclude: List(config.BotCategory),
  registry registry: ai_agents.Registry,
) -> Bool {
  let lower = string.lowercase(login)
  use <- bool.guard(
    list.any(allow, fn(a) { string.lowercase(a) == lower }),
    return: True,
  )
  use <- bool.guard(
    excluded_category(login:, exclude:, registry:) != Error(Nil),
    return: False,
  )

  case policy {
    config.AllBots -> True
    config.NoBots -> False
    config.WellKnownBots(categories) -> in_categories(lower, categories)
  }
}

/// The first `exclude` category the login belongs to, if any.
pub fn excluded_category(
  login login: String,
  exclude exclude: List(config.BotCategory),
  registry registry: ai_agents.Registry,
) -> Result(config.BotCategory, Nil) {
  let lower = string.lowercase(login)
  list.find(exclude, fn(category) {
    case category {
      config.AiAgents -> is_ai_agent(login:, registry:)
      _ -> in_categories(lower, [category])
    }
  })
}

/// Whether a bot login belongs to a known AI agent.
pub fn is_ai_agent(
  login login: String,
  registry registry: ai_agents.Registry,
) -> Bool {
  result.is_ok(ai_agents.match_login(registry:, login:))
}

/// Check if a lowercase login belongs to any of the given well-known categories.
fn in_categories(lower: String, categories: List(config.BotCategory)) -> Bool {
  list.any(categories, fn(cat) {
    list.any(bots_for_category(cat), fn(bot) { bot == lower })
  })
}

/// Get the bot logins for a category. `AiAgents` has no fixed list; it is resolved against
/// the AI agent registry.
pub fn bots_for_category(category: config.BotCategory) -> List(String) {
  case category {
    config.DependencyUpdaters -> dependency_updaters
    config.CiCd -> ci_cd
    config.Release -> release
    config.AiAgents -> []
  }
}
