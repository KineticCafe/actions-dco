# @KineticCafe/actions-dco

Enforce the presence of commit sign-offs on pull requests, indicating that the
contributor to a project certifies that they are permitted to contribute to the
project. The sign-off line represents certification of the
[Developer Certificate of Origin][dco].

Bot user contributions are automatically exempted.

## Example Usage

```yaml
name: DCO Check

on:
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v1
```

## Inputs

- `repo-token`: The GitHub token for use with this action. It must have
  sufficient permissions to read pull request details.

  Default: `${{ github.token }}`

- `exempt-authors`: A whitespace separated list of email exemption patterns
  indicating an implied DCO sign-off (the contributors work for the company
  managing the project, for example). Permitted pattern formats are exact emails
  (`name@example.org`) or domain patterns (`@example.org`). Patterns that do not
  match this will be printed as warnings and ignored.

  `exempt-authors` are applied only for the commit _author_. The commit
  _committer_ cannot exempt other peoples' contributions.

  ```yaml
  name: DCO Check

  on:
  pull_request:

  jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v1
        with:
          exempt-authors: |
            joe@example.net
            @example.com
  ```

## Contributing

@KineticCafe/actions-dco [welcomes contributions][welcomes contributions]. This
project, like all Kinetic Commerce [open source projects][open source projects],
is under the Kinetic Commerce Open Source [Code of Conduct][Code of Conduct].

This project is licensed under the Apache License, version 2.0 and requires
certification via a Developer Certificate of Origin. See
[Licence.md][Licence.md] for more details.

## Releasing

Releases are prepared with `@vercel/ncc` to produce a single file which must be
committed to `dist/`. Run `pnpm package` or `pnpm all` to produce this file.

[welcomes contributions]: https://github.com/KineticCafe/actions-dco/blob/main/Contributing.md
[code of conduct]: https://github.com/KineticCafe/code-of-conduct
[open source projects]: https://github.com/KineticCafe
[licence.md]: https://github.com/KineticCafe/actions-dco/blob/main/Licence.md
[dco]: https://developercertificate.org
