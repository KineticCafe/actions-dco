//// Runs the whole `test/fixtures/ai_commits.json` fixture through the pipeline under
//// several configurations. The fixture holds one commit per scenario:
////
//// | # | Scenario                                                              |
//// |---|-----------------------------------------------------------------------|
//// | 0 | human sign-off (control)                                              |
//// | 1 | AI Signed-off-by only                                                 |
//// | 2 | human and AI Signed-off-by                                            |
//// | 3 | AI Co-Authored-By plus a human sign-off                               |
//// | 4 | dependabot (exempt bot) carrying an AI Signed-off-by                  |
//// | 5 | `claude[bot]` account, no trailers                                    |
//// | 6 | `Copilot` bot author, human committer who signed off                  |
//// | 7 | merge commit, only a `Ticket:` trailer                                |
//// | 8 | merge commit with a human sign-off                                    |
//// | 9 | AI git author, human committer, human and AI Signed-off-by            |

import dco_check
import dco_check/config
import dco_check/internal/github/decode
import dco_check/types
import dco_check_action
import gleam/dynamic/decode as d
import gleam/json
import gleam/list
import gleam/string
import simplifile
import take

fn run(toml: String) -> #(types.DcoSummary, List(types.DcoRecord)) {
  let assert Ok(text) = simplifile.read("test/fixtures/ai_commits.json")
  let decoder = {
    use html_url <- d.field("html_url", d.string)
    use total_commits <- d.field("total_commits", d.int)
    use commits <- d.field("commits", decode.commit_decoder_list())
    d.success(#(html_url, total_commits, commits))
  }
  let assert Ok(#(url, total, commits)) = json.parse(text, decoder)
  let assert Ok(cfg) = config.parse(toml)

  let #(result, _stdout) =
    take.with_stdout(fn() {
      dco_check.get_dco_status(commits:, url:, config: cfg, total:)
    })
  result
}

fn at(records: List(types.DcoRecord), index: Int) -> types.DcoRecord {
  let assert Ok(record) = list.drop(records, index) |> list.first
  record
}

fn dispositions(records: List(types.DcoRecord)) -> List(String) {
  list.map(records, fn(record) {
    case record.disposition {
      types.Passed(..) -> "passed"
      types.AiSignoffRejected(..) -> "ai-signoff"
      types.AiCoAuthorRejected(..) -> "ai-co-author"
      types.AiTraceRejected(..) -> "ai-trace"
      types.NoSignoffs -> "no-signoffs"
      types.NoMatch(..) -> "no-match"
      types.MergeCommit -> "merge"
      types.BotCommit(..) -> "bot"
      types.Exempted(..) -> "exempt"
      types.InvalidCommit -> "invalid"
      types.Skipped(_) -> "skipped"
      types.Unprocessed -> "unprocessed"
    }
  })
}

pub fn fixture_decodes_all_commits_test() {
  let #(summary, records) = run("")
  assert list.length(records) == 10
  assert summary.total_commits == 10
  assert summary.truncated == False
}

// --- defaults: well-known bots, AI sign-offs rejected, AI co-author and AI bot checks off ---

pub fn defaults_test() {
  let #(summary, records) = run("")

  assert dispositions(records)
    == [
      "passed", "ai-signoff", "ai-signoff", "passed", "ai-signoff",
      "no-signoffs", "passed", "merge", "passed", "ai-signoff",
    ]
  assert summary.passed == 4
  assert summary.failed == 5
  assert summary.skipped_merge == 1
  assert summary.skipped_bot == 0
  assert summary.invalid == 0
}

pub fn defaults_name_the_agent_test() {
  let #(_summary, records) = run("")

  let assert types.AiSignoffRejected(agents: [match]) =
    at(records, 1).disposition
  assert match.agent == "Claude"
  assert match.identity == "Claude <noreply@anthropic.com>"
}

pub fn exempt_bot_with_ai_signoff_is_still_rejected_test() {
  let #(_summary, records) = run("")
  let assert types.AiSignoffRejected(..) = at(records, 4).disposition
}

pub fn agent_as_git_author_with_ai_signoff_is_rejected_by_default_test() {
  let #(_summary, records) = run("")
  let assert types.AiSignoffRejected(..) = at(records, 9).disposition
}

pub fn ai_bot_with_human_committer_signoff_passes_test() {
  // Copilot is not a well-known bot, so a human sign-off is required; the human
  // committer's sign-off provides it.
  let #(_summary, records) = run("")
  let assert types.Passed(..) = at(records, 6).disposition
}

pub fn passed_names_the_identity_that_signed_test() {
  // Commit 6: bot author (Copilot), human committer who signed. The row names Alice.
  let #(_summary, records) = run("")
  let assert types.Passed(identity:) = at(records, 6).disposition
  assert identity.name == "Alice Example"
}

// --- ai.signed-off-by = "require-human" ---

const with_human = "[ai]\nsigned-off-by = \"require-human\""

pub fn with_human_signoff_test() {
  let #(summary, records) = run(with_human)

  assert dispositions(records)
    == [
      "passed", "ai-signoff", "passed", "passed", "ai-signoff", "no-signoffs",
      "passed", "merge", "passed", "passed",
    ]
  assert summary.passed == 6
  assert summary.failed == 3
  assert summary.skipped_merge == 1
}

pub fn with_human_signoff_records_what_was_ignored_test() {
  let #(_summary, records) = run(with_human)

  let flagged =
    list.index_map(records, fn(record, index) { #(index, record) })
    |> list.filter(fn(entry) { entry.1.ignored_ai_signoffs != [] })
    |> list.map(fn(entry) { entry.0 })

  // Commits 2 and 9 carry both a human and an AI sign-off.
  assert flagged == [2, 9]
}

pub fn with_human_signoff_still_rejects_ai_alone_test() {
  let #(_summary, records) = run(with_human)
  let assert types.AiSignoffRejected(..) = at(records, 1).disposition
  // The exempt dependabot commit has no human sign-off to rely on.
  let assert types.AiSignoffRejected(..) = at(records, 4).disposition
}

pub fn with_human_signoff_agent_author_human_committer_passes_test() {
  let #(_summary, records) = run(with_human)
  // The agent is the git author, but the human committer's sign-off is what passed.
  let assert types.Passed(identity:) = at(records, 9).disposition
  assert identity.name == "Alice Example"
}

// --- ai.co-authored-by ---

const reject_co_authors = "[ai]\nco-authored-by = \"reject\""

pub fn reject_co_authored_by_test() {
  let #(summary, records) = run(reject_co_authors)

  assert dispositions(records)
    == [
      "passed", "ai-signoff", "ai-signoff", "ai-co-author", "ai-signoff",
      "no-signoffs", "passed", "merge", "passed", "ai-signoff",
    ]
  assert summary.failed == 6
}

pub fn reject_co_authored_by_ignores_human_co_authors_test() {
  // Commit 6 has `Co-authored-by: Alice Example`, a human.
  let #(_summary, records) = run(reject_co_authors)
  let assert types.Passed(..) = at(records, 6).disposition
}

pub fn ai_co_author_check_composes_with_with_human_signoff_test() {
  let #(summary, records) = run(with_human <> "\nco-authored-by = \"reject\"")

  assert dispositions(records)
    == [
      "passed", "ai-signoff", "passed", "ai-co-author", "ai-signoff",
      "no-signoffs", "passed", "merge", "passed", "passed",
    ]
  assert summary.passed == 5
  assert summary.failed == 4
}

// --- bot policy and bots.exclude-categories ---

const all_bots = "[bots]\npolicy = \"all\""

pub fn all_bots_exempts_ai_bots_test() {
  let #(summary, records) = run(all_bots)

  let assert types.BotCommit(login: "claude[bot]", ..) =
    at(records, 5).disposition
  let assert types.BotCommit(login: "Copilot", ..) = at(records, 6).disposition
  assert summary.skipped_bot == 2
  // The AI sign-off rejection still beats the dependabot exemption.
  let assert types.AiSignoffRejected(..) = at(records, 4).disposition
}

pub fn exclude_ai_requires_signoff_from_ai_bots_test() {
  let #(summary, records) = run(all_bots <> "\nexclude-categories = [\"ai\"]")

  assert at(records, 5).disposition == types.NoSignoffs
  let assert types.Passed(..) = at(records, 6).disposition
  assert summary.skipped_bot == 0
}

pub fn exclude_ai_bots_allow_overrides_test() {
  let #(_summary, records) =
    run(
      "[bots]\npolicy = \"all\"\nallow = [\"claude[bot]\"]\nexclude-categories = [\"ai\"]",
    )

  let assert types.BotCommit(login: "claude[bot]", ..) =
    at(records, 5).disposition
  // Copilot is not allow-listed, so it still needs the human sign-off.
  let assert types.Passed(..) = at(records, 6).disposition
}

pub fn extra_agent_email_catches_a_new_agent_test() {
  // Mark Alice's address as an agent: her sign-offs become AI sign-offs.
  let #(summary, records) =
    run("[ai]\nextra-agent-emails = [\"alice@example.com\"]")

  let assert types.AiSignoffRejected(agents: [match]) =
    at(records, 0).disposition
  assert match.agent == "AI agent (configured)"
  assert summary.passed == 0
}

// --- ai.trace-detection ---

pub fn trace_detection_test() {
  let #(summary, records) = run("[ai]\ntrace-detection = \"reject\"")

  // Commits 5 (claude[bot]) and 6 (Copilot) are agent-authored with no Assisted-by.
  // Commit 9 is agent-authored too, but its AI sign-off is rejected first.
  assert dispositions(records)
    == [
      "passed", "ai-signoff", "ai-signoff", "passed", "ai-signoff", "ai-trace",
      "ai-trace", "merge", "passed", "ai-signoff",
    ]
  assert summary.failed == 6
}

pub fn trace_detection_with_ignore_agents_test() {
  let #(_summary, records) =
    run(
      "[ai]\ntrace-detection = \"reject\"\nignore-agents = [\"github-copilot\"]",
    )

  let assert types.AiTraceRejected(..) = at(records, 5).disposition
  let assert types.Passed(..) = at(records, 6).disposition
}

pub fn trace_detection_with_tolerated_signoff_test() {
  // With the AI sign-off tolerated, commit 9 reaches trace detection.
  let #(_summary, records) = run(with_human <> "\ntrace-detection = \"reject\"")
  let assert types.AiTraceRejected(agents: [match]) = at(records, 9).disposition
  assert match.identity == "Claude <noreply@anthropic.com>"
}

// --- rendering the whole fixture ---

pub fn comment_body_for_defaults_test() {
  let #(summary, records) = run("")
  let body = dco_check_action.format_comment_body(summary, records)

  assert string.contains(body, "## ❌ DCO Check Failed")
  assert string.contains(body, "### Issues")
  assert string.contains(body, "No Signed-off-by trailer found.")
  // Four commits are rejected for an AI sign-off, each with its reason.
  assert list.length(string.split(body, "Signed-off-by names an AI agent")) == 5
  // Merge commits are labelled. Personal addresses stay masked; AI agent addresses do not.
  assert string.contains(body, "1 (no sign-off, skipped)")
  assert string.contains(body, "Claude &lt;noreply@anthropic.com&gt;")
  assert !string.contains(body, "alice@example.com")
}

pub fn comment_body_flags_ignored_ai_signoffs_test() {
  let #(summary, records) = run(with_human)
  let body = dco_check_action.format_comment_body(summary, records)

  assert string.contains(body, "🤖[^ai-signoff]")
  assert list.length(string.split(body, "[^ai-signoff]: ")) == 2
}

pub fn comment_body_reports_co_author_rejection_test() {
  let #(summary, records) = run(reject_co_authors)
  let body = dco_check_action.format_comment_body(summary, records)

  assert string.contains(body, "Co-authored-by names an AI agent")
  assert string.contains(
    body,
    "Assisted-by: &lt;agent harness&gt; [model] [tool…]",
  )
}
