//// Pipeline tests for the AI checks (sign-off, co-author, trace detection), AI bot
//// exclusion, and merge commit checking.
////
//// Commits are derived from the fixture: index 0 is a human commit (First Committer),
//// index 1 is a dependabot commit, index 3 is a merge commit.

import dco_check
import dco_check/config
import dco_check/internal/github/decode
import dco_check/internal/github/types as github_types
import dco_check/types
import dco_check_action
import gleam/dynamic/decode as d
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import take

const human_signoff =
  "Signed-off-by: First Committer <first.committer@example.org>"

const claude = "Claude <noreply@anthropic.com>"

// --- helpers ---

fn fixture() -> #(String, Int, List(github_types.Commit)) {
  let assert Ok(text) = simplifile.read("test/fixtures/commits_subset.json")
  let decoder = {
    use html_url <- d.field("html_url", d.string)
    use total_commits <- d.field("total_commits", d.int)
    use commits <- d.field("commits", decode.commit_decoder_list())
    d.success(#(html_url, total_commits, commits))
  }
  let assert Ok(result) = json.parse(text, decoder)
  result
}

fn nth(commits: List(github_types.Commit), index: Int) -> github_types.Commit {
  let assert Ok(commit) = list.drop(commits, index) |> list.first
  commit
}

fn human_commit() -> github_types.Commit {
  nth(fixture().2, 0)
}

fn with_message(
  commit: github_types.Commit,
  message: String,
) -> github_types.Commit {
  github_types.Commit(
    ..commit,
    commit: github_types.CommitCommit(..commit.commit, message:),
  )
}

/// Make the commit a merge commit by giving it the fixture merge commit's parents.
fn as_merge(commit: github_types.Commit) -> github_types.Commit {
  github_types.Commit(..commit, parents: nth(fixture().2, 3).parents)
}

/// Attribute the commit to a GitHub bot account with the given login, keeping the git
/// author/committer identity (First Committer) unchanged.
fn as_bot(commit: github_types.Commit, login: String) -> github_types.Commit {
  let assert Some(github_types.CommitAuthorSimpleUser(bot)) =
    nth(fixture().2, 1).author
  github_types.Commit(
    ..commit,
    author: Some(github_types.CommitAuthorSimpleUser(
      github_types.SimpleUser(..bot, login:),
    )),
  )
}

fn run(
  commit: github_types.Commit,
  toml: String,
) -> #(types.DcoSummary, types.DcoRecord) {
  let #(summary, record, _stdout) = run_capturing(commit, toml)
  #(summary, record)
}

fn run_capturing(
  commit: github_types.Commit,
  toml: String,
) -> #(types.DcoSummary, types.DcoRecord, String) {
  let assert Ok(cfg) = config.parse(toml)
  let #(url, _total, _commits) = fixture()
  let #(#(summary, records), stdout) =
    take.with_stdout(fn() {
      dco_check.get_dco_status(commits: [commit], url:, config: cfg, total: 1)
    })
  let assert [record] = records
  #(summary, record, stdout)
}

fn git_user(name: String, email: String) -> github_types.GitUser {
  github_types.GitUser(date: None, email: Some(email), name: Some(name))
}

/// Replace the git author identity, keeping the committer.
fn with_git_author(
  commit: github_types.Commit,
  name: String,
  email: String,
) -> github_types.Commit {
  github_types.Commit(
    ..commit,
    commit: github_types.CommitCommit(
      ..commit.commit,
      author: Some(
        github_types.CommitCommitAuthor(git_user: Some(git_user(name, email))),
      ),
    ),
  )
}

/// Replace the git committer identity, keeping the author.
fn with_git_committer(
  commit: github_types.Commit,
  name: String,
  email: String,
) -> github_types.Commit {
  github_types.Commit(
    ..commit,
    commit: github_types.CommitCommit(
      ..commit.commit,
      committer: Some(
        github_types.CommitCommitCommitter(
          git_user: Some(git_user(name, email)),
        ),
      ),
    ),
  )
}

fn disposition(
  commit: github_types.Commit,
  toml: String,
) -> types.DcoDisposition {
  run(commit, toml).1.disposition
}

fn message(trailers: List(String)) -> String {
  "feat: a change\n\n"
  <> list.fold(trailers, "", fn(acc, t) { acc <> t <> "\n" })
}

// --- AI Signed-off-by is always rejected ---

pub fn ai_signoff_rejected_test() {
  let commit =
    with_message(human_commit(), message(["Signed-off-by: " <> claude]))
  let #(summary, record) = run(commit, "")

  assert record.disposition
    == types.AiSignoffRejected(agents: [
      types.AiMatch(agent: "Claude", identity: claude),
    ])
  assert summary.failed == 1
}

pub fn ai_signoff_rejected_even_with_human_signoff_test() {
  let commit =
    with_message(
      human_commit(),
      message([human_signoff, "Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(agents: [
    types.AiMatch(agent: "Claude", ..),
  ]) = disposition(commit, "")
}

pub fn ai_signoff_reports_every_agent_test() {
  let commit =
    with_message(
      human_commit(),
      message([
        "Signed-off-by: " <> claude,
        "Signed-off-by: Cursor <cursoragent@cursor.com>",
      ]),
    )
  let assert types.AiSignoffRejected(agents:) = disposition(commit, "")
  assert list.map(agents, fn(a) { a.agent }) == ["Claude", "Cursor"]
}

pub fn ai_signoff_beats_bot_exemption_test() {
  // dependabot is exempt under the default policy, but not with an AI sign-off.
  let commit =
    with_message(
      as_bot(human_commit(), "dependabot[bot]"),
      message(["Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(..) = disposition(commit, "")
}

pub fn ai_signoff_beats_author_exemption_test() {
  let commit =
    with_message(human_commit(), message(["Signed-off-by: " <> claude]))
  let assert types.AiSignoffRejected(..) =
    disposition(commit, "exempt-authors = [\"first.committer@example.org\"]")
}

pub fn ai_signoff_beats_merge_skip_test() {
  let commit =
    with_message(
      as_merge(human_commit()),
      message(["Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(..) = disposition(commit, "")
}

pub fn ai_signoff_not_softened_by_bot_allow_test() {
  let commit =
    with_message(
      as_bot(human_commit(), "claude[bot]"),
      message(["Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(..) =
    disposition(commit, "[bots]\nallow = [\"claude[bot]\"]")
}

pub fn ai_signoff_matches_extra_agent_email_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Signed-off-by: House Bot <house@example.com>"]),
    )
  let toml = "[ai]\nextra-agent-emails = [\"house@example.com\"]"

  let assert types.NoMatch(..) = disposition(commit, "")
  let assert types.AiSignoffRejected(agents: [
    types.AiMatch(agent: "AI agent (configured)", ..),
  ]) = disposition(commit, toml)
}

pub fn ai_signoff_matches_by_email_not_name_test() {
  // The name "Claude" with a human email is not an AI sign-off.
  let commit =
    with_message(
      human_commit(),
      message(["Signed-off-by: Claude <claude.person@example.com>"]),
    )
  let assert types.NoMatch(..) = disposition(commit, "")
}

pub fn mechanical_bot_signing_off_is_still_exempt_test() {
  // dependabot signs off as support@github.com; not an AI agent, and exempt as a bot.
  let commit =
    with_message(
      as_bot(human_commit(), "dependabot[bot]"),
      message(["Signed-off-by: dependabot[bot] <support@github.com>"]),
    )
  let assert types.BotCommit(login: "dependabot[bot]", ..) =
    disposition(commit, "")
}

pub fn ai_signoff_runs_regardless_of_other_ai_settings_test() {
  let commit =
    with_message(human_commit(), message(["Signed-off-by: " <> claude]))
  let toml =
    "[ai]\nco-authored-by = \"ignore\"\ntrace-detection = \"ignore\"\nignore-agents = [\"claude\"]"
  let assert types.AiSignoffRejected(..) = disposition(commit, toml)
}

pub fn ignored_agent_sign_off_is_still_rejected_test() {
  // ai.ignore-agents never touches Signed-off-by handling.
  let commit =
    with_message(
      human_commit(),
      message([human_signoff, "Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(..) =
    disposition(commit, "[ai]\nignore-agents = [\"claude\"]")
}

pub fn ignored_agent_sign_off_never_certifies_test() {
  // An ignored agent signing its own commit is still not a human sign-off.
  let commit =
    human_commit()
    |> with_git_author("Claude", "noreply@anthropic.com")
    |> with_git_committer("Claude", "noreply@anthropic.com")
    |> with_message(message(["Signed-off-by: " <> claude]))
  let assert types.AiSignoffRejected(..) =
    disposition(
      commit,
      "[ai]\nsigned-off-by = \"require-human\"\nignore-agents = [\"claude\"]",
    )
}

pub fn co_authored_by_ai_alone_is_not_a_signoff_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, human_signoff]),
    )
  let assert types.Passed(..) = disposition(commit, "")
}

// --- ai.co-authored-by ---

const reject_co_authors = "[ai]\nco-authored-by = \"reject\""

pub fn ai_co_author_check_rejects_ai_co_author_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, human_signoff]),
    )
  assert disposition(commit, reject_co_authors)
    == types.AiCoAuthorRejected(agents: [
      types.AiMatch(agent: "Claude", identity: claude),
    ])
}

pub fn ai_co_author_check_off_by_default_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, human_signoff]),
    )
  let #(_summary, record, stdout) = run_capturing(commit, "")
  let assert types.Passed(..) = record.disposition
  assert !string.contains(stdout, "Co-authored-by names")
  let assert types.Passed(..) =
    disposition(commit, "[ai]\nco-authored-by = \"ignore\"")
}

pub fn ai_co_author_warn_passes_with_a_warning_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, human_signoff]),
    )
  let #(_summary, record, stdout) =
    run_capturing(commit, "[ai]\nco-authored-by = \"warn\"")
  let assert types.Passed(..) = record.disposition
  assert string.contains(stdout, "Co-authored-by names AI agent Claude")
  assert string.contains(stdout, "Assisted-by: <agent harness>")
}

pub fn ai_co_author_check_skips_ignore_agents_test() {
  let commit =
    with_message(
      human_commit(),
      message([
        "Co-authored-by: " <> claude,
        "Co-authored-by: Cursor <cursoragent@cursor.com>",
        human_signoff,
      ]),
    )
  let assert types.AiCoAuthorRejected(agents: [
    types.AiMatch(agent: "Cursor", ..),
  ]) =
    disposition(commit, reject_co_authors <> "\nignore-agents = [\"claude\"]")
  let assert types.Passed(..) =
    disposition(
      commit,
      reject_co_authors <> "\nignore-agents = [\"claude\", \"cursor\"]",
    )
}

pub fn ai_co_author_check_allows_human_co_author_test() {
  let commit =
    with_message(
      human_commit(),
      message([
        "Co-authored-by: Bob <bob@example.com>",
        human_signoff,
      ]),
    )
  let assert types.Passed(..) = disposition(commit, reject_co_authors)
}

pub fn ai_co_author_check_applies_to_exempt_bot_commits_test() {
  let commit =
    with_message(
      as_bot(human_commit(), "dependabot[bot]"),
      message(["Co-authored-by: " <> claude]),
    )
  let assert types.AiCoAuthorRejected(..) =
    disposition(commit, reject_co_authors)
}

pub fn ai_co_author_check_applies_to_merge_commits_test() {
  let commit =
    with_message(
      as_merge(human_commit()),
      message(["Co-authored-by: " <> claude]),
    )
  let assert types.AiCoAuthorRejected(..) =
    disposition(commit, reject_co_authors)
}

pub fn ai_signoff_rejection_wins_over_ai_co_author_rejection_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, "Signed-off-by: " <> claude]),
    )
  let assert types.AiSignoffRejected(..) =
    disposition(commit, reject_co_authors)
}

pub fn ai_co_author_check_ignores_ai_signoff_key_test() {
  // Only Co-authored-by trailers are this check's business.
  let commit =
    with_message(
      human_commit(),
      message(["Assisted-by: Claude Code", human_signoff]),
    )
  let assert types.Passed(..) = disposition(commit, reject_co_authors)
}

// --- bots.exclude-categories = ["ai"] ---

const all_bots_excluding_ai =
  "[bots]\npolicy = \"all\"\nexclude-categories = [\"ai\"]"

pub fn ai_bot_exempt_under_all_by_default_test() {
  let commit = as_bot(with_message(human_commit(), message([])), "claude[bot]")
  let assert types.BotCommit(login: "claude[bot]", ..) =
    disposition(commit, "[bots]\npolicy = \"all\"")
}

pub fn excluding_ai_requires_signoff_from_ai_bot_test() {
  let commit = as_bot(with_message(human_commit(), message([])), "claude[bot]")
  assert disposition(commit, all_bots_excluding_ai) == types.NoSignoffs
}

pub fn excluding_ai_human_signoff_passes_ai_bot_commit_test() {
  let commit =
    as_bot(
      with_message(human_commit(), message([human_signoff])),
      "claude[bot]",
    )
  let assert types.Passed(..) = disposition(commit, all_bots_excluding_ai)
}

pub fn bot_allow_beats_ai_exclusion_test() {
  let commit = as_bot(with_message(human_commit(), message([])), "claude[bot]")
  let toml = all_bots_excluding_ai <> "\nallow = [\"claude[bot]\"]"
  let assert types.BotCommit(login: "claude[bot]", ..) =
    disposition(commit, toml)
}

pub fn excluding_ai_does_not_affect_mechanical_bots_test() {
  let commit =
    as_bot(with_message(human_commit(), message([])), "dependabot[bot]")
  let assert types.BotCommit(login: "dependabot[bot]", ..) =
    disposition(commit, all_bots_excluding_ai)
}

pub fn ignore_agents_do_not_affect_bot_exclusion_test() {
  let commit = as_bot(with_message(human_commit(), message([])), "claude[bot]")
  let toml = all_bots_excluding_ai <> "\n[ai]\nignore-agents = [\"claude\"]"
  assert disposition(commit, toml) == types.NoSignoffs
}

// --- ai.trace-detection ---

fn agent_authored() -> github_types.Commit {
  human_commit()
  |> with_git_author("Claude", "noreply@anthropic.com")
  |> with_message(message([human_signoff]))
}

pub fn trace_detection_off_by_default_test() {
  let #(_summary, record, stdout) = run_capturing(agent_authored(), "")
  let assert types.Passed(..) = record.disposition
  assert !string.contains(stdout, "Assisted-by")
}

pub fn trace_detection_rejects_agent_author_without_assisted_by_test() {
  assert disposition(agent_authored(), "[ai]\ntrace-detection = \"reject\"")
    == types.AiTraceRejected(agents: [
      types.AiMatch(agent: "Claude", identity: "Claude <noreply@anthropic.com>"),
    ])
}

pub fn trace_detection_checks_the_committer_test() {
  let commit =
    human_commit()
    |> with_git_committer("Cursor", "cursoragent@cursor.com")
    |> with_message(message([human_signoff]))
  let assert types.AiTraceRejected(agents: [types.AiMatch(agent: "Cursor", ..)]) =
    disposition(commit, "[ai]\ntrace-detection = \"reject\"")
}

pub fn trace_detection_passes_with_assisted_by_test() {
  let commit =
    with_message(
      agent_authored(),
      message(["Assisted-by: Claude Code", human_signoff]),
    )
  let assert types.Passed(..) =
    disposition(commit, "[ai]\ntrace-detection = \"reject\"")
}

pub fn trace_detection_warn_passes_with_a_warning_test() {
  let #(_summary, record, stdout) =
    run_capturing(agent_authored(), "[ai]\ntrace-detection = \"warn\"")
  let assert types.Passed(..) = record.disposition
  assert string.contains(stdout, "author or committer is AI agent Claude")
  assert string.contains(stdout, "Assisted-by: <agent harness>")
}

pub fn trace_detection_skips_ignore_agents_test() {
  let assert types.Passed(..) =
    disposition(
      agent_authored(),
      "[ai]\ntrace-detection = \"reject\"\nignore-agents = [\"claude\"]",
    )
}

pub fn trace_detection_beats_merge_skip_and_bot_exemption_test() {
  let toml = "[ai]\ntrace-detection = \"reject\""
  let merge =
    as_merge(with_git_author(human_commit(), "Claude", "noreply@anthropic.com"))
  let assert types.AiTraceRejected(..) = disposition(merge, toml)

  let bot =
    as_bot(
      with_git_author(human_commit(), "Claude", "noreply@anthropic.com"),
      "claude[bot]",
    )
  let assert types.AiTraceRejected(..) =
    disposition(bot, "[bots]\nallow = [\"claude[bot]\"]\n" <> toml)
}

pub fn trace_detection_ignores_human_identities_test() {
  let assert types.Passed(..) =
    disposition(
      with_message(human_commit(), message([human_signoff])),
      "[ai]\ntrace-detection = \"reject\"",
    )
}

// --- merge commits ---

pub fn merge_without_trailers_passes_test() {
  let commit = as_merge(with_message(human_commit(), "Merge branch 'main'"))
  assert disposition(commit, "") == types.MergeCommit
}

pub fn merge_with_non_signoff_trailers_passes_test() {
  let commit =
    as_merge(with_message(
      human_commit(),
      message(["Ticket: PROJ-123", "Reviewed-by: Bob <bob@example.com>"]),
    ))
  assert disposition(commit, "") == types.MergeCommit
}

pub fn merge_with_matching_signoff_is_checked_test() {
  let commit = as_merge(with_message(human_commit(), message([human_signoff])))
  let assert types.Passed(..) = disposition(commit, "")
}

pub fn merge_with_wrong_signoff_fails_test() {
  let commit =
    as_merge(with_message(
      human_commit(),
      message(["Signed-off-by: Someone Else <else@example.com>"]),
    ))
  let assert types.NoMatch(..) = disposition(commit, "")
}

pub fn merge_summary_counts_skipped_merge_test() {
  let commit = as_merge(with_message(human_commit(), "Merge branch 'main'"))
  let #(summary, _record) = run(commit, "")
  assert summary.skipped_merge == 1
  assert summary.failed == 0
}

pub fn non_merge_without_signoff_still_fails_test() {
  let commit = with_message(human_commit(), message(["Ticket: PROJ-123"]))
  assert disposition(commit, "") == types.NoSignoffs
}

pub fn parents_helper_really_makes_a_merge_test() {
  let assert [_, _, ..] = as_merge(human_commit()).parents
}

// --- ai.signed-off-by = "require-human" ---

const with_human = "[ai]\nsigned-off-by = \"require-human\""

const ai_signoff = "Signed-off-by: Claude <noreply@anthropic.com>"

pub fn tolerated_ai_signoff_passes_with_matching_human_signoff_test() {
  let commit =
    with_message(human_commit(), message([human_signoff, ai_signoff]))
  let assert types.Passed(..) = disposition(commit, with_human)
}

pub fn tolerated_ai_signoff_warns_test() {
  let commit =
    with_message(human_commit(), message([human_signoff, ai_signoff]))
  let #(_summary, _record, stdout) = run_capturing(commit, with_human)

  assert string.contains(stdout, "require-human")
  assert string.contains(stdout, "Claude")
}

pub fn tolerated_ai_signoff_order_does_not_matter_test() {
  let commit =
    with_message(human_commit(), message([ai_signoff, human_signoff]))
  let assert types.Passed(..) = disposition(commit, with_human)
}

pub fn default_policy_still_rejects_ai_with_human_signoff_test() {
  let commit =
    with_message(human_commit(), message([human_signoff, ai_signoff]))
  let assert types.AiSignoffRejected(..) = disposition(commit, "")
  let assert types.AiSignoffRejected(..) =
    disposition(commit, "[ai]\nsigned-off-by = \"reject\"")
}

pub fn tolerated_ai_signoff_alone_is_rejected_test() {
  let commit = with_message(human_commit(), message([ai_signoff]))
  let assert types.AiSignoffRejected(..) = disposition(commit, with_human)
}

pub fn tolerated_ai_signoff_with_someone_elses_signoff_is_rejected_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Signed-off-by: Someone Else <else@example.com>", ai_signoff]),
    )
  let assert types.AiSignoffRejected(..) = disposition(commit, with_human)
}

pub fn tolerated_ai_signoff_accepts_aliased_human_signoff_test() {
  let commit =
    with_message(
      human_commit(),
      message([
        "Signed-off-by: First Committer <alias@example.com>",
        ai_signoff,
      ]),
    )
  let toml =
    with_human
    <> "\n\n[alias-signoffs.aliases]\n\"first.committer@example.org\" = [\"alias@example.com\"]"
  let assert types.Passed(..) = disposition(commit, toml)
}

pub fn exemptions_do_not_count_as_human_certification_test() {
  // Exempt bot, no human sign-off.
  let bot =
    with_message(
      as_bot(human_commit(), "dependabot[bot]"),
      message([ai_signoff]),
    )
  let assert types.AiSignoffRejected(..) = disposition(bot, with_human)

  // Exempt author, no human sign-off. Top-level keys must come before the [ai] table.
  let author = with_message(human_commit(), message([ai_signoff]))
  let assert types.AiSignoffRejected(..) =
    disposition(
      author,
      "exempt-authors = [\"first.committer@example.org\"]\n" <> with_human,
    )
}

pub fn tolerated_ai_signoff_on_merge_needs_human_signoff_test() {
  let alone = as_merge(with_message(human_commit(), message([ai_signoff])))
  let assert types.AiSignoffRejected(..) = disposition(alone, with_human)

  let signed =
    as_merge(with_message(human_commit(), message([human_signoff, ai_signoff])))
  let assert types.Passed(..) = disposition(signed, with_human)
}

pub fn tolerated_ai_signoff_on_exempt_bot_with_human_signoff_passes_test() {
  let commit =
    with_message(
      as_bot(human_commit(), "dependabot[bot]"),
      message([human_signoff, ai_signoff]),
    )
  let assert types.BotCommit(login: "dependabot[bot]", ..) =
    disposition(commit, with_human)
}

pub fn ai_identity_signing_for_itself_is_not_human_certification_test() {
  // The agent is both author and committer and signs off as itself: its sign-off matches
  // the commit identity, but it is an AI sign-off, so it must not count.
  let commit =
    human_commit()
    |> with_git_author("Claude", "noreply@anthropic.com")
    |> with_git_committer("Claude", "noreply@anthropic.com")
    |> with_message(message([ai_signoff]))
  let assert types.AiSignoffRejected(..) = disposition(commit, with_human)
}

pub fn agent_author_with_human_committer_signed_by_human_passes_test() {
  let commit =
    human_commit()
    |> with_git_author("Claude", "noreply@anthropic.com")
    |> with_message(message([human_signoff, ai_signoff]))
  let assert types.Passed(identity:) = disposition(commit, with_human)
  assert identity.name != "Claude"
}

pub fn ai_co_author_check_still_applies_when_ai_signoff_is_tolerated_test() {
  let commit =
    with_message(
      human_commit(),
      message([
        "Co-authored-by: " <> claude,
        human_signoff,
        ai_signoff,
      ]),
    )
  let toml = with_human <> "\nco-authored-by = \"reject\""
  let assert types.AiCoAuthorRejected(..) = disposition(commit, toml)
}

// --- ignored AI sign-offs are recorded for the frontends ---

pub fn tolerated_ai_signoff_is_recorded_on_the_record_test() {
  let commit =
    with_message(human_commit(), message([human_signoff, ai_signoff]))
  let #(_summary, record) = run(commit, with_human)

  let assert types.Passed(..) = record.disposition
  assert record.ignored_ai_signoffs
    == [types.AiMatch(agent: "Claude", identity: claude)]
}

pub fn records_without_ai_signoffs_have_none_ignored_test() {
  let commit = with_message(human_commit(), message([human_signoff]))
  let #(_summary, record) = run(commit, with_human)

  let assert types.Passed(..) = record.disposition
  assert record.ignored_ai_signoffs == []
}

pub fn rejected_ai_signoff_is_not_recorded_as_ignored_test() {
  let commit = with_message(human_commit(), message([ai_signoff]))
  let #(_summary, record) = run(commit, with_human)

  let assert types.AiSignoffRejected(..) = record.disposition
  assert record.ignored_ai_signoffs == []
}

// --- end to end: pipeline result renders a reason ---

pub fn ai_signoff_rejection_renders_a_reason_end_to_end_test() {
  let commit =
    with_message(human_commit(), message(["Signed-off-by: " <> claude]))
  let #(summary, record) = run(commit, "")

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "### Issues")
  assert string.contains(body, "Signed-off-by names an AI agent")
  assert string.contains(body, "Claude &lt;noreply@anthropic.com&gt;")
}

pub fn ai_co_author_rejection_renders_a_reason_end_to_end_test() {
  let commit =
    with_message(
      human_commit(),
      message(["Co-authored-by: " <> claude, human_signoff]),
    )
  let #(summary, record) = run(commit, reject_co_authors)

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "### Issues")
  assert string.contains(body, "Co-authored-by names an AI agent")
  assert string.contains(
    body,
    "Assisted-by: &lt;agent harness&gt; [model] [tool…]",
  )
}

pub fn ai_trace_rejection_renders_a_reason_end_to_end_test() {
  let #(summary, record) =
    run(agent_authored(), "[ai]\ntrace-detection = \"reject\"")

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "### Issues")
  assert string.contains(body, "The commit author or committer is an AI agent")
  assert string.contains(body, "Claude &lt;noreply@anthropic.com&gt;")
  assert string.contains(
    body,
    "Assisted-by: &lt;agent harness&gt; [model] [tool…]",
  )
}

pub fn merge_without_signoff_renders_its_label_end_to_end_test() {
  let commit = as_merge(with_message(human_commit(), "Merge branch 'main'"))
  let #(summary, record) = run(commit, "")

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "1 (no sign-off, skipped)")
}

pub fn configured_ai_address_is_masked_end_to_end_test() {
  // A private agent's address may be someone's own, so it is masked like a personal one.
  let commit =
    with_message(
      human_commit(),
      message(["Signed-off-by: House Bot <house@example.com>"]),
    )
  let #(summary, record) =
    run(commit, "[ai]\nextra-agent-emails = [\"house@example.com\"]")

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "House Bot &lt;ho…@example.com&gt;")
  assert !string.contains(body, "house@example.com")
}

pub fn personal_addresses_stay_masked_end_to_end_test() {
  // A personal address in a failure reason is still masked in the comment.
  let commit =
    with_message(
      human_commit(),
      message(["Signed-off-by: Someone Else <else@example.com>"]),
    )
  let #(summary, record) = run(commit, "")

  let body = dco_check_action.format_comment_body(summary, [record])
  assert string.contains(body, "el…@example.com")
  assert !string.contains(body, "else@example.com")
}
