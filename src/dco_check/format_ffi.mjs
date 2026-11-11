const NOREPLY = /\bno-?reply\b/i;

export function is_noreply(email) {
	return NOREPLY.test(email);
}

// A mention is a word-initial `@` plus a user (or `org/team`) name that is not followed
// by more word characters or by `.` and a word character, so `foo@bar` and
// `al…@example.com` are not mentions but `@barfoo` and `(@barfoo)` are. This mirrors
// GitHub's mention rule.
const MENTION = /(?<!\w)(@[A-Za-z0-9][-A-Za-z0-9]*(?:\/[-A-Za-z0-9]+)?)(?!\w|\.\w)/g;
// A Markdown-significant character.
const SPECIAL = /([`*_~|$]|\\|\[|\])/g;

export function escape_markdown(text) {
	return text
		.replace(SPECIAL, (_match, special) => `\\${special}`)
		.replace(MENTION, (_match, mention) => `\`${mention}\``);
}
