//// Domain types for DCO check.

import dco_check/internal/github/types
import gleam/option.{type Option}

/// A complete Git identity where both email and name are present.
pub type Identity {
  Identity(email: String, name: String)
}

/// How an author was matched for exemption.
pub type ExemptionMatch {
  ExactEmail
  DomainPattern(String)
}

/// The DCO Disposition is how the commit processed under the DCO was resolved.
pub type DcoDisposition {
  Unprocessed
  /// The commit was exempted from DCO processing by email matching.
  Exempted(identity: Identity, match: ExemptionMatch)
  /// The commit has no Signed-off-by trailers and is not exempt.
  NoSignoffs
  /// The commit has sign-offs but none match a valid commit identity.
  NoMatch(expected: List(Identity), found: List(Identity))
  /// The commit cannot be processed because neither author nor committer
  /// has both name and email.
  InvalidCommit
  /// The commit passed validation.
  Passed
  /// The commit was skipped because it is a merge commit.
  MergeCommit
  /// Allowed bot commit with structured identity.
  BotCommit(login: String, name: Option(String), email: Option(String))
  /// The commit was skipped for some other reason.
  Skipped(String)
}

/// DCO Records are commit records with information on the signoff status.
pub type DcoRecord {
  DcoRecord(
    sha: String,
    url: String,
    author: Option(types.GitUser),
    committer: Option(types.GitUser),
    identities: List(Identity),
    disposition: DcoDisposition,
  )
}

/// Summary counts for the overall DCO check result.
pub type DcoSummary {
  DcoSummary(
    total_commits: Int,
    evaluated: Int,
    passed: Int,
    failed: Int,
    invalid: Int,
    exempted: Int,
    skipped_merge: Int,
    skipped_bot: Int,
    truncated: Bool,
  )
}
