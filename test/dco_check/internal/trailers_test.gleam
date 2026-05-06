import dco_check/internal/trailers
import gleam/dict
import gleam/option.{None, Some}

// --- parse Strict ---

pub fn parse_strict_simple_signoff_test() {
  let msg = "feat: add thing\n\nSigned-off-by: Alice <alice@example.com>"

  assert [#("signed-off-by", "Alice <alice@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_multiple_trailers_test() {
  let msg =
    "fix: stuff\n\nReviewed-by: Bob <bob@example.com>\nSigned-off-by: Alice <alice@example.com>"

  assert [
      #("reviewed-by", "Bob <bob@example.com>"),
      #("signed-off-by", "Alice <alice@example.com>"),
    ]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_no_body_test() {
  let msg = "subject only\n\nSigned-off-by: Alice <alice@example.com>\n"

  assert [#("signed-off-by", "Alice <alice@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_no_trailers_test() {
  let msg = "subject\n\nThis is just a body paragraph with no trailers."

  assert [] == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_ignores_earlier_colon_lines_test() {
  let msg =
    "subject\n\nNote: this is body text\n\nSigned-off-by: Alice <alice@example.com>"

  assert [#("signed-off-by", "Alice <alice@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_crlf_normalization_test() {
  let msg = "subject\r\n\r\nSigned-off-by: Alice <alice@example.com>\r\n"

  assert [#("signed-off-by", "Alice <alice@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_folded_value_test() {
  let msg = "subject\n\nSigned-off-by: Alice\n  <alice@example.com>"

  assert [#("signed-off-by", "Alice <alice@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_rejects_block_with_non_trailer_line_test() {
  let msg =
    "subject\n\nSigned-off-by: Alice <alice@example.com>\nthis is not a trailer"

  assert [] == trailers.parse(msg, trailers.Strict)
}

pub fn parse_strict_hyphenated_key_test() {
  let msg = "subject\n\nCo-authored-by: Bob <bob@example.com>"

  assert [#("co-authored-by", "Bob <bob@example.com>")]
    == trailers.parse(msg, trailers.Strict)
}

// --- parse Lenient ---

pub fn parse_lenient_merges_separated_trailer_blocks_test() {
  let msg =
    "subject\n\nToken: value1\nSigned-off-by: Alice <alice@example.com>\n\nSigned-off-by: Bob <bob@example.com>"

  assert [
      #("token", "value1"),
      #("signed-off-by", "Alice <alice@example.com>"),
      #("signed-off-by", "Bob <bob@example.com>"),
    ]
    == trailers.parse(msg, trailers.Lenient)
}

pub fn parse_lenient_stops_at_non_trailer_block_test() {
  let msg =
    "subject\n\nThis is body text\n\nToken: value1\n\nSigned-off-by: Alice <alice@example.com>"

  assert [
      #("token", "value1"),
      #("signed-off-by", "Alice <alice@example.com>"),
    ]
    == trailers.parse(msg, trailers.Lenient)
}

pub fn parse_lenient_single_block_same_as_strict_test() {
  let msg = "subject\n\nSigned-off-by: Alice <alice@example.com>"

  assert trailers.parse(msg, trailers.Strict)
    == trailers.parse(msg, trailers.Lenient)
}

// --- group ---

pub fn group_collects_by_key_test() {
  let parsed = [
    #("signed-off-by", "Alice <alice@example.com>"),
    #("reviewed-by", "Bob <bob@example.com>"),
    #("signed-off-by", "Charlie <charlie@example.com>"),
  ]

  let result = trailers.group(parsed)

  let assert Ok(["Alice <alice@example.com>", "Charlie <charlie@example.com>"]) =
    dict.get(result, "signed-off-by")

  let assert Ok(["Bob <bob@example.com>"]) = dict.get(result, "reviewed-by")
}

// --- parse_identity ---

pub fn parse_identity_standard_format_test() {
  assert Ok(#(Some("Alice Smith"), Some("alice@example.com")))
    == trailers.parse_identity("Alice Smith <alice@example.com>")
}

pub fn parse_identity_extra_spaces_test() {
  assert Ok(#(Some("Bob Jones"), Some("bob@example.com")))
    == trailers.parse_identity("  Bob Jones   <bob@example.com>  ")
}

pub fn parse_identity_no_angle_brackets_test() {
  assert Error(Nil) == trailers.parse_identity("just a name")
}

pub fn parse_identity_empty_email_test() {
  assert Ok(#(Some("Name"), None)) == trailers.parse_identity("Name <>")
}

pub fn parse_identity_empty_name_test() {
  assert Ok(#(None, Some("alice@example.com")))
    == trailers.parse_identity("<alice@example.com>")
}

pub fn parse_identity_both_empty_test() {
  assert Ok(#(None, None)) == trailers.parse_identity("<>")
}

pub fn parse_identity_unicode_name_test() {
  assert Ok(#(Some("José García"), Some("jose@example.com")))
    == trailers.parse_identity("José García <jose@example.com>")
}

pub fn parse_identity_multiple_angle_brackets_test() {
  assert Error(Nil) == trailers.parse_identity("bob <foo> <bar>")
}
