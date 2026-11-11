import dco_check
import dco_check/config
import dco_check/error
import dco_check/internal/github/decode
import dco_check/internal/github/response_types
import dco_check/internal/github/types as github_types
import dco_check/pipeline
import dco_check/types
import gleam/dict
import gleam/dynamic/decode as d
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import take

fn load_fixture_commits() {
  let assert Ok(json) = simplifile.read("test/fixtures/commits_subset.json")
  let decoder = {
    use html_url <- d.field("html_url", d.string)
    use total_commits <- d.field("total_commits", d.int)
    use commits <- d.field("commits", decode.commit_decoder_list())
    d.success(#(html_url, total_commits, commits))
  }
  let assert Ok(result) = json.parse(json, decoder)
  result
}

fn run_dco(commits, url, config, total) {
  let #(result, _stdout) =
    take.with_stdout(fn() {
      dco_check.get_dco_status(commits:, url:, config:, total:)
    })
  result
}

// --- get_dco_status with default config (all bots exempt) ---

pub fn default_config_summary_counts_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(summary, _records) = run_dco(commits, url, config.default(), total)

  // 4 commits: 1 unsigned user (fail), 1 bot (skip), 1 signed user (pass), 1 merge (skip)
  assert summary.total_commits == 4
  assert summary.evaluated == 4
  assert summary.passed == 1
  assert summary.failed == 1
  assert summary.skipped_bot == 1
  assert summary.skipped_merge == 1
}

pub fn unsigned_user_commit_fails_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // First commit: unsigned user -> NoSignoffs
  let assert Ok(record) = list.first(records)
  assert record.disposition == types.NoSignoffs
}

pub fn signed_user_commit_passes_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // Third commit (index 2): signed user -> Passed
  let assert [_, _, record, ..] = records
  let assert types.Passed(..) = record.disposition
}

pub fn bot_commit_skipped_with_default_policy_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // Second commit (index 1): dependabot -> BotCommit
  let assert [_, record, ..] = records
  let assert types.BotCommit(login: "dependabot[bot]", ..) = record.disposition
}

pub fn merge_commit_skipped_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // Fourth commit (index 3): merge -> MergeCommit
  let assert [_, _, _, record] = records
  assert record.disposition == types.MergeCommit
}

pub fn identical_author_committer_dedupes_identities_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // First commit: author and committer are the same person
  let assert Ok(record) = list.first(records)
  assert record.identities
    == [
      types.Identity(
        name: "First Committer",
        email: "first.committer@example.org",
      ),
    ]
}

pub fn distinct_author_committer_keeps_both_identities_test() {
  let #(url, total, commits) = load_fixture_commits()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // Second commit: dependabot author, human committer
  let assert [_, record, ..] = records
  assert list.length(record.identities) == 2
}

// --- bot policy: NoBots ---

pub fn no_bots_policy_requires_signoff_test() {
  let #(url, total, commits) = load_fixture_commits()
  let assert Ok(cfg) = config.parse("[bots]\npolicy = \"none\"")
  let #(summary, records) = run_dco(commits, url, cfg, total)

  // Bot commit now passes (it has a valid signoff from support@github.com)
  // but only if alias is configured. Without alias, the signoff email doesn't
  // match the commit author email, so it should fail with NoMatch.
  let assert [_, bot_record, ..] = records
  let assert types.NoMatch(..) = bot_record.disposition
  assert summary.skipped_bot == 0
}

// --- bot policy: NoBots with alias ---

pub fn no_bots_with_alias_passes_test() {
  let #(url, total, commits) = load_fixture_commits()
  let assert Ok(cfg) =
    config.parse(
      "[bots]\npolicy = \"none\"\n\n[alias-signoffs.aliases]\n\"49699333+dependabot[bot]@users.noreply.github.com\" = [\"support@github.com\"]",
    )
  let #(_summary, records) = run_dco(commits, url, cfg, total)

  let assert [_, bot_record, ..] = records
  let assert types.Passed(..) = bot_record.disposition
}

// --- exempt-authors ---

pub fn exempt_author_exact_email_test() {
  let #(url, total, commits) = load_fixture_commits()
  let assert Ok(cfg) =
    config.parse("exempt-authors = [\"first.committer@example.org\"]")
  let #(summary, records) = run_dco(commits, url, cfg, total)

  // First commit (unsigned user with first.committer@example.org) should now be exempted
  let assert Ok(record) = list.first(records)
  let assert types.Exempted(
    identity: types.Identity(email: "first.committer@example.org", ..),
    match: types.ExactEmail,
    alias: option.None,
  ) = record.disposition
  assert summary.exempted == 1
}

pub fn exempt_author_domain_pattern_test() {
  let #(url, total, commits) = load_fixture_commits()
  let assert Ok(cfg) = config.parse("exempt-authors = [\"@example.org\"]")
  let #(summary, records) = run_dco(commits, url, cfg, total)

  let assert Ok(record) = list.first(records)
  let assert types.Exempted(match: types.DomainPattern("@example.org"), ..) =
    record.disposition
  assert summary.exempted == 1
}

// --- find_author_exemption ---

fn author_record(name: String, email: String) -> types.DcoRecord {
  types.DcoRecord(
    sha: "abc",
    url: "http://x",
    subject: "test",
    author: Some(github_types.GitUser(
      email: Some(email),
      name: Some(name),
      date: Some("2024-01-01"),
    )),
    committer: option.None,
    identities: [types.Identity(email:, name:)],
    ignored_ai_signoffs: [],
    disposition: types.Unprocessed,
  )
}

fn exemption(
  record: types.DcoRecord,
  exemptions: config.Exemptions,
  aliases: dict.Dict(String, List(String)),
) {
  take.with_stdout(fn() {
    dco_check.find_author_exemption(record:, exemptions:, aliases:)
  }).0
}

pub fn find_author_exemption_no_match_test() {
  let record = author_record("Alice", "alice@example.com")
  let exemptions = config.Exemptions(exact: ["bob@example.com"], ends_with: [])

  assert exemption(record, exemptions, dict.new()) == option.None
}

pub fn find_author_exemption_exact_match_test() {
  let record = author_record("Alice", "alice@example.com")
  let exemptions =
    config.Exemptions(exact: ["alice@example.com"], ends_with: [])

  let assert Some(#(
    types.Identity(email: "alice@example.com", ..),
    types.ExactEmail,
    option.None,
  )) = exemption(record, exemptions, dict.new())
}

pub fn find_author_exemption_domain_match_test() {
  let record = author_record("Alice", "alice@corp.dev")
  let exemptions = config.Exemptions(exact: [], ends_with: ["@corp.dev"])

  let assert Some(#(_, types.DomainPattern("@corp.dev"), option.None)) =
    exemption(record, exemptions, dict.new())
}

// --- Regression: null top-level author/committer (GitHub issue #216) ---
// When a commit's author email is not linked to any GitHub account,
// the compare API returns "author": null / "committer": null at the
// top level. This must decode and process successfully.

fn load_null_author_fixture() {
  let assert Ok(json) =
    simplifile.read("test/fixtures/null_author_commits.json")
  let decoder = {
    use html_url <- d.field("html_url", d.string)
    use total_commits <- d.field("total_commits", d.int)
    use commits <- d.field("commits", decode.commit_decoder_list())
    d.success(#(html_url, total_commits, commits))
  }
  let assert Ok(result) = json.parse(json, decoder)
  result
}

pub fn null_author_commits_decode_test() {
  // The fixture must decode without error — this was the original crash.
  let #(_url, _total, commits) = load_null_author_fixture()
  assert list.length(commits) == 2
}

pub fn null_author_signed_commit_passes_test() {
  let #(url, total, commits) = load_null_author_fixture()
  let #(_summary, records) = run_dco(commits, url, config.default(), total)

  // First commit has a valid Signed-off-by matching the git identity.
  let assert [record, ..] = records
  let assert types.Passed(..) = record.disposition
}

pub fn null_author_unsigned_commit_fails_test() {
  let #(url, total, commits) = load_null_author_fixture()
  let #(summary, records) = run_dco(commits, url, config.default(), total)

  // Second commit has no sign-off trailer.
  let assert [_, record] = records
  assert record.disposition == types.NoSignoffs
  assert summary.passed == 1
  assert summary.failed == 1
}

// --- Regression: actionable decode error messages ---
// When the commit comparison JSON has a malformed author object (e.g. missing
// required fields on SimpleUser), the error message must tell the user what
// field failed and where, not just "Failed to decode commit comparison JSON".

pub fn malformed_author_produces_actionable_error_test() {
  let assert Ok(json_body) =
    simplifile.read("test/fixtures/malformed_author_commits.json")
  let response = response_types.ReposCompareCommitsResponseOk(json_body)

  let assert #(Error(err), _stdout) =
    take.with_stdout(fn() {
      pipeline.process_response(response:, config: config.default())
    })
  let message = error.describe_error(err)

  // The error message must mention the decode failure context — not be a
  // generic "Failed to decode" with no path info.
  assert string.contains(message, "expected")
  assert string.contains(message, "got")
}

pub fn find_author_exemption_ignores_email_case_test() {
  let record =
    types.DcoRecord(
      sha: "abc",
      url: "http://x",
      subject: "test",
      author: Some(github_types.GitUser(
        email: Some("Alice@Corp.Dev"),
        name: Some("Alice"),
        date: Some("2024-01-01"),
      )),
      committer: option.None,
      identities: [types.Identity(email: "Alice@Corp.Dev", name: "Alice")],
      ignored_ai_signoffs: [],
      disposition: types.Unprocessed,
    )

  // Exact entry and domain pattern, each written in a different case than the author.
  let exact = config.Exemptions(exact: ["alice@corp.dev"], ends_with: [])
  let assert Some(#(
    types.Identity(email: "Alice@Corp.Dev", ..),
    types.ExactEmail,
    option.None,
  )) = exemption(record, exact, dict.new())

  let domain = config.Exemptions(exact: [], ends_with: ["@CORP.dev"])
  let assert Some(#(_, types.DomainPattern("@CORP.dev"), option.None)) =
    exemption(record, domain, dict.new())
}

// --- exemption through alias-signoffs.aliases ---

const noreply = "123+me@users.noreply.github.com"

fn aliases() -> dict.Dict(String, List(String)) {
  dict.from_list([#(noreply, ["austin@zieglers.ca"])])
}

pub fn find_author_exemption_through_alias_test() {
  let record = author_record("Austin", noreply)
  let exemptions = config.Exemptions(exact: [], ends_with: ["@zieglers.ca"])

  let assert Some(#(
    types.Identity(email: "123+me@users.noreply.github.com", ..),
    types.DomainPattern("@zieglers.ca"),
    Some("austin@zieglers.ca"),
  )) = exemption(record, exemptions, aliases())
}

pub fn find_author_exemption_prefers_own_address_test() {
  let record = author_record("Austin", noreply)
  let exemptions =
    config.Exemptions(exact: [noreply], ends_with: ["@zieglers.ca"])

  let assert Some(#(_, types.ExactEmail, option.None)) =
    exemption(record, exemptions, aliases())
}

pub fn find_author_exemption_ignores_committer_aliases_test() {
  // The committer's alias never exempts the author.
  let record =
    types.DcoRecord(
      ..author_record("Bob", "bob@example.com"),
      committer: Some(github_types.GitUser(
        email: Some(noreply),
        name: Some("Austin"),
        date: Some("2024-01-01"),
      )),
    )
  let exemptions = config.Exemptions(exact: [], ends_with: ["@zieglers.ca"])

  assert exemption(record, exemptions, aliases()) == option.None
}

pub fn find_author_exemption_alias_is_one_hop_test() {
  let record = author_record("Austin", noreply)
  let chained =
    dict.from_list([
      #(noreply, ["middle@example.com"]),
      #("middle@example.com", ["austin@zieglers.ca"]),
    ])
  let exemptions = config.Exemptions(exact: [], ends_with: ["@zieglers.ca"])

  assert exemption(record, exemptions, chained) == option.None
}

pub fn alias_exemption_through_pipeline_test() {
  let #(url, total, commits) = load_fixture_commits()
  let assert Ok(cfg) =
    config.parse(
      "exempt-authors = [\"@zieglers.ca\"]\n[alias-signoffs.aliases]\n\"first.committer@example.org\" = [\"first@zieglers.ca\"]",
    )
  let #(summary, records) = run_dco(commits, url, cfg, total)

  let assert Ok(record) = list.first(records)
  let assert types.Exempted(
    match: types.DomainPattern("@zieglers.ca"),
    alias: Some("first@zieglers.ca"),
    ..,
  ) = record.disposition
  assert summary.exempted == 1
}
