import dco_check/format
import dco_check/types
import gleam/list
import gleam/option.{None}
import gleam/string

// --- sha ---

pub fn sha_abbreviates_to_twelve_characters_test() {
  assert format.sha("65ac7481582616c33142e752a5ad185103b4e90b")
    == "65ac74815826"
}

pub fn sha_leaves_short_values_alone_test() {
  assert format.sha("abc") == "abc"
}

// --- subject ---

pub fn subject_is_the_first_line_test() {
  assert format.subject("feat: add thing\n\nA longer body.")
    == "feat: add thing"
}

pub fn subject_without_a_newline_is_the_message_test() {
  assert format.subject("fix: one-liner") == "fix: one-liner"
}

pub fn subject_of_exactly_fifty_characters_is_kept_test() {
  let fifty = string.repeat("a", 50)
  assert format.subject(fifty) == fifty
}

pub fn subject_over_fifty_characters_is_truncated_test() {
  let long = string.repeat("a", 51)
  assert format.subject(long <> "\nbody") == string.repeat("a", 50) <> "…"
}

// --- signoff ---

pub fn signoff_test() {
  let identity = types.Identity(name: "Alice", email: "alice@example.com")
  assert format.signoff(identity) == "\"Alice <alice@example.com>\""
}

pub fn signoff_masked_masks_personal_addresses_test() {
  let identity = types.Identity(name: "Alice", email: "alice@example.com")
  assert format.signoff_masked(identity) == "\"Alice <al…@example.com>\""
}

pub fn signoff_masked_leaves_noreply_addresses_test() {
  let identity =
    types.Identity(name: "Alice", email: "12345+alice@users.noreply.github.com")
  assert format.signoff_masked(identity)
    == "\"Alice <12345+alice@users.noreply.github.com>\""
}

// --- mask_email ---

pub fn mask_email_normal_test() {
  assert format.mask_email("alice@example.com") == "al…@example.com"
}

pub fn mask_email_short_local_one_char_test() {
  assert format.mask_email("a@example.net") == "a…@example.net"
}

pub fn mask_email_short_local_two_chars_test() {
  assert format.mask_email("ab@example.net") == "ab…@example.net"
}

pub fn mask_email_long_local_test() {
  assert format.mask_email("verylongname@domain.org") == "ve…@domain.org"
}

pub fn mask_email_no_at_test() {
  assert format.mask_email("notanemail") == "…"
}

pub fn mask_email_noreply_test() {
  // GitHub noreply addresses are public by design: not masked.
  assert format.mask_email("49699333+dependabot[bot]@users.noreply.github.com")
    == "49699333+dependabot[bot]@users.noreply.github.com"
}

// --- mask_email: the word `noreply` (/\bno-?reply\b/i) ---

pub fn mask_email_noreply_forges_test() {
  // GitHub (both forms), Codeberg, a Gitea default, and a vendor address.
  list.each(
    [
      "alice@users.noreply.github.com",
      "12345+alice@users.noreply.github.com",
      "noreply@github.com",
      "alice@noreply.codeberg.org",
      "alice@noreply.git.example.org",
      "noreply@anthropic.com",
      "alice@users.noreply.gitlab.com",
    ],
    fn(email) {
      assert format.mask_email(email) == email
    },
  )
}

pub fn mask_email_noreply_is_case_insensitive_test() {
  assert format.mask_email("NoReply@Example.COM") == "NoReply@Example.COM"
}

pub fn mask_email_noreply_needs_whole_word_test() {
  // Not the standalone word, so these are masked like any personal address.
  assert format.mask_email("noreplyfan@example.com") == "no…@example.com"
  assert format.mask_email("xnoreply@example.com") == "xn…@example.com"
  assert format.mask_email("my_noreply@example.com") == "my…@example.com"
  assert format.mask_email("alice@mynoreply.example.com")
    == "al…@mynoreply.example.com"
  assert format.mask_email("noreply1@example.com") == "no…@example.com"
}

pub fn mask_email_hyphenated_no_reply_is_not_masked_test() {
  // `\bno-?reply\b` matches `no-reply` as well as `noreply`.
  assert format.mask_email("no-reply@example.com") == "no-reply@example.com"
  assert format.mask_email("alice@no-reply.example.org")
    == "alice@no-reply.example.org"
}

pub fn mask_email_finds_a_later_whole_word_after_a_partial_one_test() {
  assert format.mask_email("xnoreply.noreply@example.com")
    == "xnoreply.noreply@example.com"
}

// --- mask_email: AI agents are never masked ---

pub fn mask_email_leaves_built_in_ai_addresses_alone_test() {
  // None of these contain the word `noreply`.
  list.each(
    [
      "cursoragent@cursor.com",
      "copilot@github.com",
      "gemini@google.com",
      "openhands@all-hands.dev",
      "crush@charm.land",
      "qwen-coder@alibabacloud.com",
    ],
    fn(email) {
      assert format.mask_email(email) == email
    },
  )
}

pub fn mask_email_ai_match_is_case_insensitive_test() {
  assert format.mask_email("CursorAgent@Cursor.com") == "CursorAgent@Cursor.com"
}

pub fn mask_email_still_masks_personal_addresses_test() {
  assert format.mask_email("alice@example.com") == "al…@example.com"
  assert format.mask_email("alice@cursor.com") == "al…@cursor.com"
}

// --- AI messages ---

pub fn ai_match_is_the_trailer_as_written_test() {
  let match =
    types.AiMatch(agent: "Cursor", identity: "Cursor <cursoragent@cursor.com>")
  assert format.ai_match(match) == "Cursor <cursoragent@cursor.com>"
}

pub fn describe_ai_signoff_rejected_test() {
  let message =
    format.describe_ai_signoff_rejected([
      "Claude <noreply@anthropic.com>",
      "Cursor <cursoragent@cursor.com>",
    ])

  assert string.starts_with(message, "Signed-off-by names an AI agent (")
  assert string.contains(
    message,
    "Claude <noreply@anthropic.com>, Cursor <cursoragent@cursor.com>",
  )
  assert string.contains(message, "AI agents cannot certify the DCO")
  assert string.contains(message, "git rebase --signoff")
}

pub fn describe_ai_co_author_rejected_test() {
  let message =
    format.describe_ai_co_author_rejected(["Claude <noreply@anthropic.com>"])

  assert string.starts_with(message, "Co-authored-by names an AI agent (")
  assert string.contains(message, "does not co-author")
  assert string.contains(
    message,
    "Assisted-by: <agent harness> [model] [tool…]",
  )
}

// --- ignored AI sign-off marker ---

fn record(ignored: List(types.AiMatch)) -> types.DcoRecord {
  types.DcoRecord(
    sha: "abc123",
    url: "https://github.com/test/repo/commits/abc123",
    subject: "subject",
    author: None,
    committer: None,
    identities: [],
    ignored_ai_signoffs: ignored,
    disposition: types.Passed(identity: types.Identity(
      name: "Alice",
      email: "alice@example.com",
    )),
  )
}

pub fn has_ignored_ai_signoff_test() {
  let match = types.AiMatch(agent: "Claude", identity: "Claude <c@x.y>")
  assert format.has_ignored_ai_signoff(record([match]))
  assert !format.has_ignored_ai_signoff(record([]))
}

pub fn marker_and_footnote_are_fixed_test() {
  assert format.ai_signoff_marker == "🤖"
  assert string.contains(format.ai_signoff_footnote, "AI agents cannot certify")
}

// --- is_noreply: addresses that are no-reply addresses ---

pub fn is_noreply_forge_addresses_test() {
  list.each(
    [
      // GitHub, both forms
      "alice@users.noreply.github.com",
      "12345+alice@users.noreply.github.com",
      "49699333+dependabot[bot]@users.noreply.github.com",
      // GitHub web-UI committer
      "noreply@github.com",
      // Codeberg (Forgejo) and the Gitea default `noreply.<host>`
      "alice@noreply.codeberg.org",
      "alice@noreply.git.example.org",
      // GitLab
      "alice@users.noreply.gitlab.com",
    ],
    fn(email) {
      assert format.is_noreply(email)
    },
  )
}

pub fn is_noreply_vendor_addresses_test() {
  list.each(
    ["noreply@anthropic.com", "noreply@aider.chat", "noreply@opencode.ai"],
    fn(email) {
      assert format.is_noreply(email)
    },
  )
}

pub fn is_noreply_hyphenated_test() {
  list.each(
    ["no-reply@example.com", "alice@no-reply.example.org", "NO-REPLY@X.COM"],
    fn(email) {
      assert format.is_noreply(email)
    },
  )
}

pub fn is_noreply_case_insensitive_test() {
  assert format.is_noreply("NoReply@Example.COM")
  assert format.is_noreply("alice@USERS.NOREPLY.GITHUB.COM")
}

pub fn is_noreply_finds_a_later_whole_word_after_a_partial_one_test() {
  assert format.is_noreply("xnoreply.noreply@example.com")
}

// --- is_noreply: addresses that are not ---

pub fn is_noreply_rejects_personal_addresses_test() {
  list.each(
    ["alice@example.com", "cursoragent@cursor.com", "copilot@github.com", ""],
    fn(email) {
      assert !format.is_noreply(email)
    },
  )
}

pub fn is_noreply_rejects_partial_words_test() {
  list.each(
    [
      "noreplyfan@example.com",
      "xnoreply@example.com",
      "my_noreply@example.com",
      "noreply1@example.com",
      "alice@mynoreply.example.com",
      "reno-reply@example.com",
      "nonoreply@example.com",
    ],
    fn(email) {
      assert !format.is_noreply(email)
    },
  )
}

pub fn is_noreply_accepts_only_a_single_optional_hyphen_test() {
  assert !format.is_noreply("no--reply@example.com")
  assert !format.is_noreply("no_reply@example.com")
  assert !format.is_noreply("no.reply@example.com")
  assert !format.is_noreply("no reply@example.com")
}

// --- escape_markdown: Markdown-significant characters ---

pub fn escape_markdown_leaves_plain_text_alone_test() {
  list.each(
    [
      "feat: add parser (v2), fixes #12",
      "Alice <alice@example.com>",
      "a < b & c > d \"quoted\" 'single'",
      "",
    ],
    fn(text) {
      assert format.escape_markdown(text) == text
    },
  )
}

pub fn escape_markdown_escapes_pipes_test() {
  // An unescaped pipe would split the table cell.
  assert format.escape_markdown("a | b") == "a \\| b"
}

pub fn escape_markdown_escapes_backslashes_test() {
  assert format.escape_markdown("a\\b") == "a\\\\b"
}

pub fn escape_markdown_escapes_code_and_emphasis_test() {
  assert format.escape_markdown("`code`") == "\\`code\\`"
  assert format.escape_markdown("*bold* and _it_ and ~~gone~~")
    == "\\*bold\\* and \\_it\\_ and \\~\\~gone\\~\\~"
}

pub fn escape_markdown_escapes_links_and_footnotes_test() {
  assert format.escape_markdown("[click](http://example.test)")
    == "\\[click\\](http://example.test)"
  // A subject must not be able to forge the footnote reference the comment uses.
  assert format.escape_markdown("[^ai-signoff]") == "\\[^ai-signoff\\]"
}

pub fn escape_markdown_escapes_math_delimiters_test() {
  assert format.escape_markdown("$x$") == "\\$x\\$"
}

pub fn escape_markdown_escapes_every_special_character_test() {
  assert format.escape_markdown("\\`*_~[]|$") == "\\\\\\`\\*\\_\\~\\[\\]\\|\\$"
}

// --- escape_markdown: @mentions ---

pub fn escape_markdown_wraps_a_word_initial_mention_test() {
  assert format.escape_markdown("@barfoo") == "`@barfoo`"
  assert format.escape_markdown("fix for @alice and @bob-smith.")
    == "fix for `@alice` and `@bob-smith`."
  assert format.escape_markdown("(@alice)") == "(`@alice`)"
}

pub fn escape_markdown_wraps_team_mentions_test() {
  assert format.escape_markdown("@org/team-name please")
    == "`@org/team-name` please"
}

pub fn escape_markdown_does_not_wrap_an_at_inside_a_word_test() {
  // `foo@bar` does not mention `@bar`.
  assert format.escape_markdown("foo@bar") == "foo@bar"
  assert format.escape_markdown("alice@example.com") == "alice@example.com"
}

pub fn escape_markdown_does_not_wrap_a_masked_email_test() {
  // `…` is not a word character, but `@example.com` is a domain, not a user.
  assert format.escape_markdown("Alice <al…@example.com>")
    == "Alice <al…@example.com>"
  assert format.escape_markdown("exempt domain @corp.dev")
    == "exempt domain @corp.dev"
}

pub fn escape_markdown_wraps_a_bare_at_name_but_not_a_domain_test() {
  assert format.escape_markdown("exempt domain @corp")
    == "exempt domain `@corp`"
  assert format.escape_markdown("thanks @alice.") == "thanks `@alice`."
}

pub fn escape_markdown_ignores_an_at_with_no_name_test() {
  list.each(["@", "@ bob", "@-x", "a @ b"], fn(text) {
    assert format.escape_markdown(text) == text
  })
}

pub fn escape_markdown_wraps_a_name_followed_by_an_underscore_test() {
  // GitHub names cannot contain `_`, so `@alice_` may mention `@alice`. Wrapping is the
  // safe side: an unneeded code span is harmless, a missed mention pings someone.
  assert format.escape_markdown("@alice_") == "`@alice`\\_"
}

pub fn escape_markdown_escapes_around_a_mention_test() {
  assert format.escape_markdown("*@alice*") == "\\*`@alice`\\*"
  assert format.escape_markdown("`@bob`") == "\\``@bob`\\`"
}
