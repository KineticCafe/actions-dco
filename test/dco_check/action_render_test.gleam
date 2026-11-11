import dco_check/types
import dco_check_action
import envoy
import gleam/list
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
  // Brackets are Markdown-escaped in the comment source; they render as `dependabot[bot]`.
  assert string.contains(body, "dependabot\\[bot\\]")
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

pub fn comment_body_exempt_via_alias_masks_the_alias_test() {
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
  let record =
    types.DcoRecord(
      ..exempt_record(
        "eee555",
        "fix: web edit",
        "Austin",
        "123+me@users.noreply.github.com",
        types.DomainPattern("@zieglers.ca"),
      ),
      disposition: types.Exempted(
        identity: types.Identity(
          name: "Austin",
          email: "123+me@users.noreply.github.com",
        ),
        match: types.DomainPattern("@zieglers.ca"),
        alias: Some("austin@zieglers.ca"),
      ),
    )

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "123+me@users.noreply.github.com")
  assert string.contains(
    body,
    "exempt domain @zieglers.ca via alias au…@zieglers.ca",
  )
  assert !string.contains(body, "austin@zieglers.ca")
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

pub fn write_summary_escapes_html_test() {
  use file <- with_summary_file("escapes_html")

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
    passed_record("aaa111", "feat: good", "Alice", "alice@example.com"),
    no_match_record("bbb222", "fix: handle <T> generics"),
  ]

  assert Ok(Nil) == dco_check_action.write_summary(summary, records)

  let assert Ok(content) = simplifile.read(file)
  // Problem cell
  assert string.contains(content, "Alice &lt;al…@example.com&gt;")
  // A GitHub noreply address is public by design: not masked.
  assert string.contains(
    content,
    "Alice &lt;alice@users.noreply.github.com&gt;",
  )
  assert !string.contains(content, "al…@users.noreply.github.com")
  // Subject cell
  assert string.contains(content, "fix: handle &lt;T&gt; generics")
  assert !string.contains(content, "<T>")
  // Success identity cell
  assert !string.contains(content, "<al…@example.com>")
}

pub fn comment_body_escapes_html_test() {
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
  let records = [no_match_record("bbb222", "feat: thing")]

  let body = dco_check_action.format_comment_body(summary, records)
  assert string.contains(body, "Alice &lt;al…@example.com&gt;")
  assert !string.contains(body, "<al…@example.com>")
}

// --- helpers ---

fn no_match_record(sha: String, subject: String) -> types.DcoRecord {
  let id = types.Identity(name: "Alice", email: "alice@example.com")
  types.DcoRecord(
    sha:,
    url: "https://github.com/test/repo/commits/" <> sha,
    subject:,
    author: None,
    committer: None,
    identities: [id],
    ignored_ai_signoffs: [],
    disposition: types.NoMatch(expected: [id], found: [
      types.Identity(name: "Alice", email: "alice@users.noreply.github.com"),
    ]),
  )
}

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
    ignored_ai_signoffs: [],
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
    ignored_ai_signoffs: [],
    disposition: types.Passed(identity: types.Identity(name:, email:)),
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
    ignored_ai_signoffs: [],
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
    ignored_ai_signoffs: [],
    disposition: types.Exempted(
      identity: types.Identity(name:, email:),
      match:,
      alias: None,
    ),
  )
}

// --- ignored AI sign-offs ---

fn with_ignored_ai_signoff(record: types.DcoRecord) -> types.DcoRecord {
  types.DcoRecord(..record, ignored_ai_signoffs: [
    types.AiMatch(agent: "Claude", identity: "Claude <noreply@anthropic.com>"),
  ])
}

fn passing_summary(count: Int) -> types.DcoSummary {
  types.DcoSummary(
    total_commits: count,
    evaluated: count,
    passed: count,
    failed: 0,
    invalid: 0,
    exempted: 0,
    skipped_merge: 0,
    skipped_bot: 0,
    truncated: False,
  )
}

const footnote_text =
  "This commit also carried a `Signed-off-by` from an AI agent, which was ignored because a human sign-off is also present. AI agents cannot certify the DCO."

pub fn comment_body_flags_ignored_ai_signoff_test() {
  let records = [
    with_ignored_ai_signoff(passed_record(
      "aaa111",
      "feat: one",
      "Alice",
      "alice@example.com",
    )),
  ]

  let body = dco_check_action.format_comment_body(passing_summary(1), records)
  assert string.contains(body, "1 (signed off 🤖[^ai-signoff])")
  assert string.contains(body, "\n\n[^ai-signoff]: " <> footnote_text)
}

pub fn comment_body_footnote_defined_once_test() {
  let records = [
    with_ignored_ai_signoff(passed_record(
      "aaa111",
      "feat: one",
      "Alice",
      "alice@example.com",
    )),
    with_ignored_ai_signoff(passed_record(
      "bbb222",
      "feat: two",
      "Bob",
      "bob@example.com",
    )),
  ]

  let body = dco_check_action.format_comment_body(passing_summary(2), records)
  assert list.length(string.split(body, "[^ai-signoff]: ")) == 2
}

pub fn comment_body_no_marker_without_ignored_signoff_test() {
  let records = [
    passed_record("aaa111", "feat: one", "Alice", "alice@example.com"),
  ]

  let body = dco_check_action.format_comment_body(passing_summary(1), records)
  assert string.contains(body, "1 (signed off)")
  assert !string.contains(body, "🤖")
  assert !string.contains(body, "[^ai-signoff]")
}

pub fn comment_body_groups_flagged_rows_apart_test() {
  let records = [
    passed_record("aaa111", "feat: one", "Alice", "alice@example.com"),
    with_ignored_ai_signoff(passed_record(
      "bbb222",
      "feat: two",
      "Alice",
      "alice@example.com",
    )),
  ]

  let body = dco_check_action.format_comment_body(passing_summary(2), records)
  assert string.contains(body, "1 (signed off)")
  assert string.contains(body, "1 (signed off 🤖[^ai-signoff])")
}

pub fn comment_body_no_footnote_when_flagged_commit_failed_test() {
  // A footnote with no reference would render as stray text.
  let records = [with_ignored_ai_signoff(failed_record("fff666", "feat: bad"))]
  let summary = types.DcoSummary(..passing_summary(1), passed: 0, failed: 1)

  let body = dco_check_action.format_comment_body(summary, records)
  assert !string.contains(body, "[^ai-signoff]")
}

pub fn write_summary_flags_ignored_ai_signoff_test() {
  use file <- with_summary_file("ignored_ai_signoff")

  let records = [
    with_ignored_ai_signoff(passed_record(
      "aaa111",
      "feat: one",
      "Alice",
      "alice@example.com",
    )),
  ]

  assert Ok(Nil) == dco_check_action.write_summary(passing_summary(1), records)

  let assert Ok(content) = simplifile.read(file)
  assert string.contains(content, "signed off 🤖")
  // The job summary table is HTML, so the footnote is plain text, not Markdown syntax.
  assert string.contains(content, "🤖 " <> footnote_text)
  assert !string.contains(content, "[^ai-signoff]")
}

pub fn write_summary_no_footnote_without_ignored_signoff_test() {
  use file <- with_summary_file("no_ignored_ai_signoff")

  let records = [
    passed_record("aaa111", "feat: one", "Alice", "alice@example.com"),
  ]

  assert Ok(Nil) == dco_check_action.write_summary(passing_summary(1), records)

  let assert Ok(content) = simplifile.read(file)
  assert !string.contains(content, "🤖")
  assert !string.contains(content, "AI agent")
}

// --- AI rejections ---

const claude_match =
  types.AiMatch(
    agent: "Claude",
    identity: "Claude Opus 4.6 <noreply@anthropic.com>",
  )

fn ai_signoff_record(sha: String, subject: String) -> types.DcoRecord {
  types.DcoRecord(
    ..failed_record(sha, subject),
    disposition: types.AiSignoffRejected(agents: [claude_match]),
  )
}

fn ai_co_author_record(sha: String, subject: String) -> types.DcoRecord {
  types.DcoRecord(
    ..failed_record(sha, subject),
    disposition: types.AiCoAuthorRejected(agents: [claude_match]),
  )
}

fn failing_summary() -> types.DcoSummary {
  types.DcoSummary(..passing_summary(1), passed: 0, failed: 1)
}

pub fn comment_body_renders_ai_signoff_rejection_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      ai_signoff_record("aaa111", "feat: agent work"),
    ])

  assert string.contains(body, "## ❌ DCO Check Failed")
  assert string.contains(body, "### Issues")
  assert string.contains(body, "feat: agent work")
  assert string.contains(body, "Signed-off-by names an AI agent")
  assert string.contains(body, "AI agents cannot certify the DCO")
  assert string.contains(body, "git rebase --signoff")
  // Angle brackets are escaped, and a noreply address is public by design: not masked.
  assert string.contains(body, "Claude Opus 4.6 &lt;noreply@anthropic.com&gt;")
  assert !string.contains(body, "no…@anthropic.com")
}

pub fn comment_body_renders_ai_co_author_rejection_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      ai_co_author_record("bbb222", "feat: assisted work"),
    ])

  assert string.contains(body, "Co-authored-by names an AI agent")
  assert string.contains(body, "does not co-author")
  assert string.contains(
    body,
    "Assisted-by: &lt;agent harness&gt; [model] [tool…]",
  )
  assert string.contains(body, "Claude Opus 4.6 &lt;noreply@anthropic.com&gt;")
}

pub fn comment_body_ai_rejection_problem_cell_is_not_empty_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      ai_signoff_record("aaa111", "feat: agent work"),
    ])

  assert !string.contains(body, "|  |")
}

pub fn write_summary_renders_ai_rejections_test() {
  use file <- with_summary_file("ai_rejections")

  let summary = types.DcoSummary(..passing_summary(2), passed: 0, failed: 2)
  let records = [
    ai_signoff_record("aaa111", "feat: agent work"),
    ai_co_author_record("bbb222", "feat: assisted work"),
  ]

  assert Ok(Nil) == dco_check_action.write_summary(summary, records)

  let assert Ok(content) = simplifile.read(file)
  assert string.contains(content, "DCO Check Failed")
  assert string.contains(content, "Signed-off-by names an AI agent")
  assert string.contains(content, "Co-authored-by names an AI agent")
  assert string.contains(
    content,
    "Claude Opus 4.6 &lt;noreply@anthropic.com&gt;",
  )
  assert !string.contains(content, "no…@anthropic.com")
  assert !string.contains(content, "<agent harness>")
}

pub fn comment_body_labels_merge_commits_test() {
  let merge =
    types.DcoRecord(
      ..failed_record("ccc333", "Merge branch 'main'"),
      disposition: types.MergeCommit,
    )
  let summary =
    types.DcoSummary(..passing_summary(1), passed: 0, skipped_merge: 1)

  let body = dco_check_action.format_comment_body(summary, [merge])
  assert string.contains(body, "merge commits")
  assert string.contains(body, "1 (no sign-off, skipped)")
}

pub fn built_in_ai_addresses_are_never_masked_but_configured_ones_are_test() {
  let cursor =
    types.AiMatch(agent: "Cursor", identity: "Cursor <cursoragent@cursor.com>")
  let configured =
    types.AiMatch(
      agent: "AI agent (configured)",
      identity: "House Bot <house@example.com>",
    )
  let record =
    types.DcoRecord(
      ..failed_record("ddd444", "feat: agents"),
      disposition: types.AiSignoffRejected(agents: [cursor, configured]),
    )

  let body = dco_check_action.format_comment_body(failing_summary(), [record])
  // Built-in agent: shown in full, even without `noreply`.
  assert string.contains(body, "Cursor &lt;cursoragent@cursor.com&gt;")
  assert !string.contains(body, "cu…@cursor.com")
  // Configured agent: may be someone's own address, so masked.
  assert string.contains(body, "House Bot &lt;ho…@example.com&gt;")
  assert !string.contains(body, "house@example.com")
}

// --- Markdown escaping: PR comment only ---

const hostile_subject = "fix: a | b *c* @alice [x](y) _z_"

pub fn comment_body_escapes_markdown_in_subjects_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      failed_record("aaa111", hostile_subject),
    ])

  assert string.contains(
    body,
    "fix: a \\| b \\*c\\* `@alice` \\[x\\](y) \\_z\\_",
  )
  // The raw pipe would have split the row into extra cells.
  assert !string.contains(body, "a | b")
}

pub fn comment_body_keeps_one_row_per_failure_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      failed_record("aaa111", hostile_subject),
    ])

  let rows =
    string.split(body, "\n")
    |> list.filter(fn(line) { string.starts_with(line, "| [`") })
  assert list.length(rows) == 1
}

pub fn comment_body_escapes_identities_test() {
  let summary = passing_summary(1)
  let body =
    dco_check_action.format_comment_body(summary, [
      passed_record("aaa111", "feat: one", "Al*ice_", "alice@example.com"),
    ])

  assert string.contains(body, "Al\\*ice\\_ &lt;al…@example.com&gt;")
}

pub fn comment_body_does_not_mention_through_an_exemption_domain_test() {
  let summary = types.DcoSummary(..passing_summary(1), passed: 0, exempted: 1)
  let body =
    dco_check_action.format_comment_body(summary, [
      exempt_record(
        "ddd444",
        "feat: internal",
        "Bob",
        "bob@corp",
        types.DomainPattern("@corp"),
      ),
    ])

  assert string.contains(body, "exempt domain `@corp`")
}

pub fn comment_body_escapes_ai_match_values_test() {
  let record =
    types.DcoRecord(
      ..failed_record("eee555", "feat: agents"),
      disposition: types.AiSignoffRejected(agents: [
        types.AiMatch(
          agent: "AI agent (configured)",
          identity: "House_Bot <house@example.com>",
        ),
      ]),
    )

  let body = dco_check_action.format_comment_body(failing_summary(), [record])
  assert string.contains(body, "House\\_Bot &lt;ho…@example.com&gt;")
}

pub fn comment_body_leaves_fixed_advice_text_unescaped_test() {
  let body =
    dco_check_action.format_comment_body(failing_summary(), [
      ai_co_author_record("fff666", "feat: assisted"),
    ])

  // The policy's own placeholder syntax is not touched by Markdown escaping.
  assert string.contains(
    body,
    "Assisted-by: &lt;agent harness&gt; [model] [tool…]",
  )
}

pub fn write_summary_does_not_markdown_escape_test() {
  use file <- with_summary_file("no_markdown_escape")

  let records = [
    failed_record("aaa111", hostile_subject),
    types.DcoRecord(
      ..failed_record("eee555", "feat: agents"),
      disposition: types.AiSignoffRejected(agents: [
        types.AiMatch(
          agent: "AI agent (configured)",
          identity: "House_Bot <house@example.com>",
        ),
      ]),
    ),
  ]
  let summary = types.DcoSummary(..passing_summary(2), passed: 0, failed: 2)

  assert Ok(Nil) == dco_check_action.write_summary(summary, records)

  let assert Ok(content) = simplifile.read(file)
  // The job summary is an HTML table: a backslash would show literally.
  assert string.contains(content, "fix: a | b *c* @alice [x](y) _z_")
  // A configured agent address is masked; Markdown escaping does not apply here.
  assert string.contains(content, "House_Bot &lt;ho…@example.com&gt;")
  assert !string.contains(content, "\\|")
  assert !string.contains(content, "\\_")
  assert !string.contains(content, "`@alice`")
}
