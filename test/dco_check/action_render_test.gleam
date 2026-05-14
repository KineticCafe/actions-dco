import dco_check/types
import dco_check_action
import envoy
import gleam/option.{None, Some}
import gleam/string
import simplifile

// --- format_comment_body ---

pub fn comment_body_all_passed_bot_test() {
  let summary =
    types.DcoSummary(
      total_commits: 1,
      evaluated: 1,
      passed: 0,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 1,
      truncated: False,
    )
  let records = [
    bot_record("abc123", "deps: Bump actions group", "dependabot[bot]"),
  ]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "## ✅ DCO Check Passed")
  assert string.contains(body, "dependabot[bot]")
  assert string.contains(body, "bot, skipped")
  assert string.contains(body, "1 (bot, skipped)")
  assert !string.contains(body, "Issues")
}

pub fn comment_body_failure_test() {
  let summary =
    types.DcoSummary(
      total_commits: 2,
      evaluated: 2,
      passed: 1,
      failed: 1,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: False,
    )
  let records = [
    passed_record("aaa111", "feat: good commit", "Alice", "alice@example.com"),
    failed_record("bbb222", "feat: bad commit"),
  ]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "## ❌ DCO Check Failed")
  assert string.contains(body, "### Issues")
  assert string.contains(body, "feat: bad commit")
  assert string.contains(body, "No Signed-off-by trailer found.")
  assert string.contains(body, "### Commits")
  assert string.contains(body, "Alice")
  assert string.contains(body, "signed off")
}

pub fn comment_body_masks_email_test() {
  let summary =
    types.DcoSummary(
      total_commits: 1,
      evaluated: 1,
      passed: 1,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: False,
    )
  let records = [
    passed_record("ccc333", "feat: thing", "Alice", "alice@example.com"),
  ]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "al…@example.com")
  assert !string.contains(body, "alice@example.com")
}

pub fn comment_body_truncated_test() {
  let summary =
    types.DcoSummary(
      total_commits: 300,
      evaluated: 250,
      passed: 250,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: True,
    )

  let body = dco_check_action.format_comment_body(summary, [])
  assert string.contains(body, "250")
  assert string.contains(body, "300")
  assert string.contains(body, "GitHub API limit")
}

pub fn comment_body_groups_same_identity_test() {
  let summary =
    types.DcoSummary(
      total_commits: 3,
      evaluated: 3,
      passed: 3,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: False,
    )
  let records = [
    passed_record("aaa111", "feat: one", "Alice", "alice@example.com"),
    passed_record("bbb222", "feat: two", "Alice", "alice@example.com"),
    passed_record("ccc333", "feat: three", "Alice", "alice@example.com"),
  ]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "3 (signed off)")
}

pub fn comment_body_exempt_domain_test() {
  let summary =
    types.DcoSummary(
      total_commits: 1,
      evaluated: 1,
      passed: 0,
      failed: 0,
      invalid: 0,
      exempted: 1,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: False,
    )
  let records = [
    exempt_record(
      "ddd444",
      "feat: internal",
      "Bob",
      "bob@corp.dev",
      types.DomainPattern("@corp.dev"),
    ),
  ]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "exempt domain @corp.dev")
}

// --- write_summary ---

pub fn write_summary_bot_skipped_test() {
  use file <- with_summary_file("bot_skipped")

  let summary =
    types.DcoSummary(
      total_commits: 1,
      evaluated: 1,
      passed: 0,
      failed: 0,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 1,
      truncated: False,
    )
  let records = [
    bot_record("abc123", "deps: Bump actions group", "dependabot[bot]"),
  ]

  assert Ok(Nil) == dco_check_action.write_summary(summary, records)

  let assert Ok(content) = simplifile.read(file)
  assert string.contains(content, "DCO Check Passed")
  assert string.contains(content, "dependabot[bot]")
  assert string.contains(content, "bot, skipped")
}

pub fn write_summary_failure_test() {
  use file <- with_summary_file("failure")

  let summary =
    types.DcoSummary(
      total_commits: 1,
      evaluated: 1,
      passed: 0,
      failed: 1,
      invalid: 0,
      exempted: 0,
      skipped_merge: 0,
      skipped_bot: 0,
      truncated: False,
    )
  let records = [failed_record("fff666", "feat: unsigned")]

  assert Ok(Nil) == dco_check_action.write_summary(summary, records)

  let assert Ok(content) = simplifile.read(file)
  assert string.contains(content, "DCO Check Failed")
  assert string.contains(content, "feat: unsigned")
  assert string.contains(content, "No Signed-off-by trailer")
}

// --- helpers ---

fn with_summary_file(name: String, body: fn(String) -> a) -> a {
  let dir = "test/_temp/" <> name
  let _ = simplifile.delete(dir)
  assert Ok(Nil) == simplifile.create_directory_all(dir)
  let file = dir <> "/SUMMARY"
  assert Ok(Nil) == simplifile.write(file, "")
  envoy.set("GITHUB_STEP_SUMMARY", file)
  envoy.set("GITHUB_ACTIONS", "true")
  let result = body(file)
  envoy.unset("GITHUB_STEP_SUMMARY")
  envoy.unset("GITHUB_ACTIONS")
  let _ = simplifile.delete(dir)
  result
}

fn bot_record(sha: String, subject: String, login: String) -> types.DcoRecord {
  types.DcoRecord(
    sha:,
    url: "https://github.com/test/repo/commits/" <> sha,
    subject:,
    author: None,
    committer: None,
    identities: [],
    disposition: types.BotCommit(login:, name: Some(login), email: None),
  )
}

fn passed_record(
  sha: String,
  subject: String,
  name: String,
  email: String,
) -> types.DcoRecord {
  types.DcoRecord(
    sha:,
    url: "https://github.com/test/repo/commits/" <> sha,
    subject:,
    author: None,
    committer: None,
    identities: [types.Identity(name:, email:)],
    disposition: types.Passed,
  )
}

fn failed_record(sha: String, subject: String) -> types.DcoRecord {
  types.DcoRecord(
    sha:,
    url: "https://github.com/test/repo/commits/" <> sha,
    subject:,
    author: None,
    committer: None,
    identities: [types.Identity(name: "Someone", email: "x@y.com")],
    disposition: types.NoSignoffs,
  )
}

fn exempt_record(
  sha: String,
  subject: String,
  name: String,
  email: String,
  match: types.ExemptionMatch,
) -> types.DcoRecord {
  types.DcoRecord(
    sha:,
    url: "https://github.com/test/repo/commits/" <> sha,
    subject:,
    author: None,
    committer: None,
    identities: [types.Identity(name:, email:)],
    disposition: types.Exempted(identity: types.Identity(name:, email:), match:),
  )
}
