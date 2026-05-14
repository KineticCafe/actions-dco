import dco_check/config.{
  AllBots, Allowlist, CiCd, DependencyUpdaters, NoBots, Release, WellKnownBots,
}
import dco_check/internal/bots
import dco_check/internal/trailers

// --- is_bot_exempt: AllBots ---

pub fn all_bots_exempts_any_login_test() {
  assert bots.is_bot_exempt(login: "random[bot]", policy: AllBots) == True
}

// --- is_bot_exempt: NoBots ---

pub fn no_bots_rejects_all_test() {
  assert bots.is_bot_exempt(login: "dependabot[bot]", policy: NoBots) == False
}

// --- is_bot_exempt: WellKnownBots ---

pub fn well_known_empty_categories_matches_all_test() {
  assert bots.is_bot_exempt(
      login: "dependabot[bot]",
      policy: WellKnownBots(categories: []),
    )
    == True
  assert bots.is_bot_exempt(
      login: "github-actions[bot]",
      policy: WellKnownBots(categories: []),
    )
    == True
  assert bots.is_bot_exempt(
      login: "release-please[bot]",
      policy: WellKnownBots(categories: []),
    )
    == True
}

pub fn well_known_specific_category_test() {
  assert bots.is_bot_exempt(
      login: "dependabot[bot]",
      policy: WellKnownBots(categories: [DependencyUpdaters]),
    )
    == True
  assert bots.is_bot_exempt(
      login: "github-actions[bot]",
      policy: WellKnownBots(categories: [DependencyUpdaters]),
    )
    == False
}

pub fn well_known_rejects_unknown_bot_test() {
  assert bots.is_bot_exempt(
      login: "my-custom[bot]",
      policy: WellKnownBots(categories: []),
    )
    == False
}

pub fn well_known_case_insensitive_test() {
  assert bots.is_bot_exempt(
      login: "Dependabot[bot]",
      policy: WellKnownBots(categories: [DependencyUpdaters]),
    )
    == True
}

pub fn well_known_ci_cd_category_test() {
  assert bots.is_bot_exempt(
      login: "github-actions[bot]",
      policy: WellKnownBots(categories: [CiCd]),
    )
    == True
}

pub fn well_known_release_category_test() {
  assert bots.is_bot_exempt(
      login: "semantic-release[bot]",
      policy: WellKnownBots(categories: [Release]),
    )
    == True
  assert bots.is_bot_exempt(
      login: "release-please[bot]",
      policy: WellKnownBots(categories: [Release]),
    )
    == True
}

// --- is_bot_exempt: Allowlist ---

pub fn allowlist_matches_listed_bot_test() {
  assert bots.is_bot_exempt(
      login: "dependabot[bot]",
      policy: Allowlist(allow: ["dependabot[bot]"]),
    )
    == True
}

pub fn allowlist_rejects_unlisted_bot_test() {
  assert bots.is_bot_exempt(
      login: "renovate[bot]",
      policy: Allowlist(allow: ["dependabot[bot]"]),
    )
    == False
}

pub fn allowlist_case_insensitive_test() {
  assert bots.is_bot_exempt(
      login: "Dependabot[bot]",
      policy: Allowlist(allow: ["dependabot[bot]"]),
    )
    == True
}

// --- has_ai_attribution ---

pub fn no_ai_trailers_test() {
  let msg = "feat: add thing\n\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == False
}

pub fn assisted_by_claude_test() {
  let msg =
    "feat: add thing\n\nAssisted-by: Claude (Anthropic)\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == True
}

pub fn co_authored_by_copilot_test() {
  let msg =
    "feat: add thing\n\nCo-authored-by: GitHub Copilot\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == True
}

pub fn ai_trailer_case_insensitive_value_test() {
  let msg =
    "feat: add thing\n\nAssisted-by: GEMINI (Google)\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == True
}

pub fn non_ai_co_authored_by_test() {
  let msg =
    "feat: add thing\n\nCo-authored-by: Bob <bob@example.com>\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == False
}

pub fn assisted_by_kiro_test() {
  let msg =
    "feat: add thing\n\nAssisted-by: Kiro\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == True
}

pub fn assisted_by_cursor_test() {
  let msg =
    "feat: add thing\n\nAssisted-by: Cursor AI\nSigned-off-by: Alice <alice@example.com>"
  assert bots.has_ai_attribution(trailers.parse(msg, trailers.Strict)) == True
}
