//// Well-known bot registry and AI trailer detection.
////
//// Bot categories group bots by purpose.
////
//// AI trailer detection is hardcoded (not user-configurable) and used to revoke bot
//// exemptions when enabled. It is disabled by default with no documented configuration
//// surface.

import dco_check/config
import gleam/list
import gleam/string

/// Well-known bots grouped by category.
pub const dependency_updaters = [
  "dependabot[bot]",
  "renovate[bot]",
  "snyk-bot[bot]",
]

pub const ci_cd = ["github-actions[bot]"]

pub const release = ["semantic-release[bot]", "release-please[bot]"]

/// AI attribution trailer keys (lowercase, as returned by trailer parser).
const ai_trailer_keys = ["assisted-by", "co-authored-by"]

/// Patterns in trailer values that indicate AI involvement.
const ai_patterns = ["claude", "copilot", "gpt", "gemini", "kiro", "cursor"]

/// Resolve whether a bot login is exempt under the given policy.
pub fn is_bot_exempt(
  login login: String,
  policy policy: config.BotPolicy,
) -> Bool {
  case policy {
    config.AllBots -> True
    config.NoBots -> False
    config.WellKnownBots(categories) -> is_well_known(login, categories)
    config.Allowlist(allow) ->
      list.any(allow, fn(a) { string.lowercase(a) == string.lowercase(login) })
  }
}

/// Check if a login belongs to any of the specified well-known categories.
/// Empty categories list means all categories.
fn is_well_known(login: String, categories: List(config.BotCategory)) -> Bool {
  let lower = string.lowercase(login)
  let cats = case categories {
    [] -> [config.DependencyUpdaters, config.CiCd, config.Release]
    _ -> categories
  }

  list.any(cats, fn(cat) {
    list.any(bots_for_category(cat), fn(bot) { bot == lower })
  })
}

/// Get the bot logins for a category.
pub fn bots_for_category(category: config.BotCategory) -> List(String) {
  case category {
    config.DependencyUpdaters -> dependency_updaters
    config.CiCd -> ci_cd
    config.Release -> release
  }
}

/// Check if parsed trailers contain AI attribution.
/// Returns True if any AI trailer with a matching AI pattern is found.
pub fn has_ai_attribution(parsed: List(#(String, String))) -> Bool {
  list.any(parsed, fn(trailer) {
    let #(key, value) = trailer
    let lower_value = string.lowercase(value)

    list.contains(ai_trailer_keys, key)
    && list.any(ai_patterns, fn(pattern) {
      string.contains(lower_value, pattern)
    })
  })
}
