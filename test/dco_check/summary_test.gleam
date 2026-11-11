import dco_check
import dco_check/types
import gleam/list
import gleam/option.{None}

fn record(disposition: types.DcoDisposition) -> types.DcoRecord {
  types.DcoRecord(
    sha: "abc123",
    url: "https://github.com/test/repo/commits/abc123",
    subject: "subject",
    author: None,
    committer: None,
    identities: [],
    ignored_ai_signoffs: [],
    disposition:,
  )
}

fn summarize(dispositions: List(types.DcoDisposition)) -> types.DcoSummary {
  let count = list.length(dispositions)
  dco_check.build_summary(
    records: list.map(dispositions, record),
    total: count,
    count:,
  )
}

const claude =
  types.AiMatch(agent: "Claude", identity: "Claude <noreply@anthropic.com>")

pub fn ai_signoff_rejected_counts_as_failed_test() {
  let summary = summarize([types.AiSignoffRejected(agents: [claude])])
  assert summary.failed == 1
  assert summary.passed == 0
  assert summary.skipped_bot == 0
}

pub fn ai_co_author_rejected_counts_as_failed_test() {
  let summary = summarize([types.AiCoAuthorRejected(agents: [claude])])
  assert summary.failed == 1
}

pub fn mixed_dispositions_test() {
  let summary =
    summarize([
      types.Passed(identity: types.Identity(
        name: "Alice",
        email: "alice@example.com",
      )),
      types.NoSignoffs,
      types.AiSignoffRejected(agents: [claude]),
      types.AiCoAuthorRejected(agents: [claude]),
      types.InvalidCommit,
      types.MergeCommit,
      types.BotCommit(login: "dependabot[bot]", name: None, email: None),
    ])

  assert summary.passed == 1
  assert summary.failed == 3
  assert summary.invalid == 1
  assert summary.skipped_merge == 1
  assert summary.skipped_bot == 1
  assert summary.evaluated == 7
  assert summary.truncated == False
}
