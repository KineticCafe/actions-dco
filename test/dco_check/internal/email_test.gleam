import dco_check/internal/email

// --- valid addresses ---

pub fn simple_valid_test() {
  assert email.is_valid("alice@example.com") == True
}

pub fn plus_addressing_test() {
  assert email.is_valid("user+tag@example.com") == True
}

pub fn dots_in_mailbox_test() {
  assert email.is_valid("first.last@example.com") == True
}

pub fn noreply_github_test() {
  assert email.is_valid("12345+user@users.noreply.github.com") == True
}

pub fn subdomain_test() {
  assert email.is_valid("user@mail.corp.example.org") == True
}

pub fn case_insensitive_test() {
  assert email.is_valid("User@Example.COM") == True
}

pub fn punycode_domain_test() {
  assert email.is_valid("user@xn--nxasmq6b.example") == True
}

pub fn special_mailbox_chars_test() {
  assert email.is_valid("a!b#c$d%e&f'g*h+i/j=k?l^m_n`o{p|q}r~s@example.com")
    == True
}

pub fn hyphenated_domain_test() {
  assert email.is_valid("user@my-domain.example.com") == True
}

// --- invalid addresses ---

pub fn missing_at_test() {
  assert email.is_valid("userexample.com") == False
}

pub fn double_at_test() {
  assert email.is_valid("user@@example.com") == False
}

pub fn empty_mailbox_test() {
  assert email.is_valid("@example.com") == False
}

pub fn empty_domain_test() {
  assert email.is_valid("user@") == False
}

pub fn leading_dot_mailbox_test() {
  assert email.is_valid(".user@example.com") == False
}

pub fn trailing_dot_mailbox_test() {
  assert email.is_valid("user.@example.com") == False
}

pub fn consecutive_dots_mailbox_test() {
  assert email.is_valid("user..name@example.com") == False
}

pub fn domain_label_starts_with_hyphen_test() {
  assert email.is_valid("user@-example.com") == False
}

pub fn domain_label_ends_with_hyphen_test() {
  assert email.is_valid("user@example-.com") == False
}

pub fn single_label_domain_test() {
  assert email.is_valid("user@localhost") == False
}

pub fn domain_label_too_short_test() {
  assert email.is_valid("user@example.c") == False
}

pub fn non_punycode_double_hyphen_test() {
  assert email.is_valid("user@ab--cd.example.com") == False
}

pub fn space_in_mailbox_test() {
  assert email.is_valid("us er@example.com") == False
}

pub fn empty_string_test() {
  assert email.is_valid("") == False
}

pub fn just_at_test() {
  assert email.is_valid("@") == False
}
