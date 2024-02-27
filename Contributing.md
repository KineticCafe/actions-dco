# Contributing

We value contributions to @KineticCafe/actions-dco—bug reports, feature
requests, and code contributions.

Before contributing patches, please read the [Licence.md](./Licence.md).

@KineticCafe/actions-dco is governed under the Kinetic Commerce Open Source
[Code of Conduct][].

## Code Guidelines

Our usual code contribution guidelines apply:

- Code changes _will not_ be accepted without tests. The test suite is written
  with [vitest][].
- Match our coding style. We use Biome to assist with this.
- Use a thoughtfully-named topic branch that contains your change. Rebase your
  commits into logical chunks as necessary.
- Use [quality commit messages][].
- The version number must not be changed except as part of the release process.
- Submit a pull request with your changes.
- New or changed behaviours require new or updated documentation.

A pull request will be accepted only if all code quality checks performed in
GitHub Actions pass.

@KineticCafe/actions-dco is compiled into a single file with `@vercel/ncc` for
release. One of the status checks is that there are no changes during the
packaging process. Ensure that you run `pnpm all` and commit any files in
`dist/` once you are satisfied with your changes.

[code of conduct]: https://github.com/KineticCafe/code-of-conduct
[quality commit messages]: http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html
[vitest]: https://vitest.dev/
