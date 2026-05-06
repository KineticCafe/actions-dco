//// Email validation via linear scan (no regex).
////
//// Validates email addresses using _simplified_ RFC 5321 rules:
////
//// - Exactly one @
//// - Mailbox: 1-64 chars, permitted charset, no leading/trailing/consecutive dots
//// - Domain: labels separated by dots, each 2-63 chars, LDH rule, punycode support

import gleam/bool
import gleam/list
import gleam/string

/// Validate an email address. Case-insensitive.
pub fn is_valid(email: String) -> Bool {
  let lower = string.lowercase(email)
  case string.split_once(lower, "@") {
    Ok(#(mailbox, domain)) ->
      is_mailbox(mailbox) && is_domain(domain, string.length(mailbox))
    Error(Nil) -> False
  }
}

fn is_mailbox(mailbox: String) -> Bool {
  let len = string.length(mailbox)
  len >= 1
  && len <= 64
  && !string.starts_with(mailbox, ".")
  && !string.ends_with(mailbox, ".")
  && !string.contains(mailbox, "..")
  && string.to_graphemes(mailbox) |> list.all(is_mailbox_char)
}

fn is_domain(domain: String, mailbox_len: Int) -> Bool {
  let max_domain = 254 - mailbox_len - 1
  let len = string.length(domain)
  len >= 4
  && len <= max_domain
  && {
    let labels = string.split(domain, ".")
    list.length(labels) >= 2 && list.all(labels, is_domain_label)
  }
}

fn is_domain_label(label: String) -> Bool {
  let len = string.length(label)
  len >= 2
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
