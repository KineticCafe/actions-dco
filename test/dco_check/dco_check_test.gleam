import dco_check
import dco_check/config
import dco_check/internal/github/decode
import dco_check/internal/github/types as github_types
import dco_check/types
import gleam/dynamic/decode as d
import gleam/json
import gleam/list
import gleam/option.{Some}
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
  assert record.disposition == types.Passed
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
  assert bot_record.disposition == types.Passed
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

pub fn find_author_exemption_no_match_test() {
  let record =
    types.DcoRecord(
      sha: "abc",
      url: "http://x",
      subject: "test",
      author: Some(github_types.GitUser(
        email: Some("alice@example.com"),
        name: Some("Alice"),
        date: Some("2024-01-01"),
      )),
      committer: option.None,
      identities: [types.Identity(email: "alice@example.com", name: "Alice")],
      disposition: types.Unprocessed,
    )
  let exemptions = config.Exemptions(exact: ["bob@example.com"], ends_with: [])

  assert take.with_stdout(fn() {
      dco_check.find_author_exemption(record:, exemptions:)
    }).0
    == option.None
}

pub fn find_author_exemption_exact_match_test() {
  let record =
    types.DcoRecord(
      sha: "abc",
      url: "http://x",
      subject: "test",
      author: Some(github_types.GitUser(
        email: Some("alice@example.com"),
        name: Some("Alice"),
        date: Some("2024-01-01"),
      )),
      committer: option.None,
      identities: [types.Identity(email: "alice@example.com", name: "Alice")],
      disposition: types.Unprocessed,
    )
  let exemptions =
    config.Exemptions(exact: ["alice@example.com"], ends_with: [])

  let assert Some(#(
    types.Identity(email: "alice@example.com", ..),
    types.ExactEmail,
  )) =
    take.with_stdout(fn() {
      dco_check.find_author_exemption(record:, exemptions:)
    }).0
}

pub fn find_author_exemption_domain_match_test() {
  let record =
    types.DcoRecord(
      sha: "abc",
      url: "http://x",
      subject: "test",
      author: Some(github_types.GitUser(
        email: Some("alice@corp.dev"),
        name: Some("Alice"),
        date: Some("2024-01-01"),
      )),
      committer: option.None,
      identities: [types.Identity(email: "alice@corp.dev", name: "Alice")],
      disposition: types.Unprocessed,
    )
  let exemptions = config.Exemptions(exact: [], ends_with: ["@corp.dev"])

  let assert Some(#(_, types.DomainPattern("@corp.dev"))) =
    take.with_stdout(fn() {
      dco_check.find_author_exemption(record:, exemptions:)
    }).0
}

// --- mask_email ---

pub fn mask_email_normal_test() {
  assert dco_check.mask_email("alice@example.com") == "al…@example.com"
}

pub fn mask_email_short_local_one_char_test() {
  assert dco_check.mask_email("a@example.net") == "a…@example.net"
}

pub fn mask_email_short_local_two_chars_test() {
  assert dco_check.mask_email("ab@example.net") == "ab…@example.net"
}

pub fn mask_email_long_local_test() {
  assert dco_check.mask_email("verylongname@domain.org") == "ve…@domain.org"
}

pub fn mask_email_no_at_test() {
  assert dco_check.mask_email("notanemail") == "…"
}

pub fn mask_email_noreply_test() {
  assert dco_check.mask_email(
      "49699333+dependabot[bot]@users.noreply.github.com",
    )
    == "49…@users.noreply.github.com"
}
