//// Email validation via linear scan (no regex).
////
//// Validates email addresses using _simplified_ RFC 5321 rules:
////
//// - Exactly one @
//// - Mailbox: 1-64 chars, permitted charset, no leading/trailing/consecutive dots. As a
////   deliberate exception, the mailbox may end in `[bot]`, as GitHub bot noreply
////   addresses do (`49699333+dependabot[bot]@users.noreply.github.com`). Brackets are not
////   permitted anywhere else.
//// - Domain: at least two labels separated by dots, each 1-63 chars, LDH rule, punycode
////   support

import gleam/bool
import gleam/list
import gleam/string

const bot_suffix = "[bot]"

/// Validate an email address. Case-insensitive.
pub fn is_valid(email: String) -> Bool {
  let lower = string.lowercase(email)
  case string.split_once(lower, "@") {
    Ok(#(mailbox, domain)) ->
      is_mailbox(mailbox) && is_domain(domain, string.length(mailbox))
    Error(Nil) -> False
  }
}

/// Validate a domain pattern: `@` followed by a domain that `is_valid` would accept.
pub fn is_domain_pattern(pattern: String) -> Bool {
  case string.lowercase(pattern) {
    "@" <> domain -> !string.contains(domain, "@") && is_domain(domain, 1)
    _ -> False
  }
}

fn is_mailbox(mailbox: String) -> Bool {
  let len = string.length(mailbox)
  let base = case string.ends_with(mailbox, bot_suffix) {
    True -> string.drop_end(mailbox, string.length(bot_suffix))
    False -> mailbox
  }

  len <= 64
  && base != ""
  && !string.starts_with(base, ".")
  && !string.ends_with(base, ".")
  && !string.contains(base, "..")
  && string.to_graphemes(base) |> list.all(is_mailbox_char)
}

fn is_domain(domain: String, mailbox_len: Int) -> Bool {
  let max_domain = 254 - mailbox_len - 1
  let len = string.length(domain)
  len >= 1
  && len <= max_domain
  && {
    let labels = string.split(domain, ".")
    list.length(labels) >= 2 && list.all(labels, is_domain_label)
  }
}

fn is_domain_label(label: String) -> Bool {
  let len = string.length(label)
  len >= 1
  && len <= 63
  && !string.starts_with(label, "-")
  && !string.ends_with(label, "-")
  && check_label_hyphens(label, len)
  && string.to_graphemes(label) |> list.all(is_label_char)
}

/// Consecutive hyphens at positions 3-4 are only permitted for punycode (xn--).
fn check_label_hyphens(label: String, len: Int) -> Bool {
  use <- bool.guard(len < 4, return: True)

  case string.slice(label, 2, 2) {
    "--" -> string.starts_with(label, "xn--")
    _ -> True
  }
}

fn is_mailbox_char(ch: String) -> Bool {
  case ch {
    "."
    | "!"
    | "#"
    | "$"
    | "%"
    | "&"
    | "'"
    | "*"
    | "+"
    | "/"
    | "="
    | "?"
    | "^"
    | "_"
    | "`"
    | "{"
    | "|"
    | "}"
    | "~"
    | "-" -> True
    _ -> is_alphanumeric(ch)
  }
}

fn is_label_char(ch: String) -> Bool {
  case ch {
    "-" -> True
    _ -> is_alphanumeric(ch)
  }
}

fn is_alphanumeric(ch: String) -> Bool {
  case ch {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9" -> True
    _ -> False
  }
}
