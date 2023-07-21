/**
 * Copyright 2023 Kinetic Commerce and contributors.
 * Based on work by Copyright 2021 tison <wander4096@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// This script is inspired by probot/dco with modifications to adopt GitHub Actions.

/**
 * ISC License
 *
 * Copyright (c) [probot/dco contributors](https://github.com/probot/dco/graphs/contributors)
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

import * as core from '@actions/core'
import * as github from '@actions/github'
import * as validator from 'email-validator'

import type { Endpoints } from '@octokit/types'

type ResponseType = Endpoints['GET /repos/{owner}/{repo}/compare/{basehead}']['response']
type CommitCompare = ResponseType['data']
type Commits = CommitCompare['commits']

type Committer = {
  email: string
  name: string
}

type DCOFailed = {
  sha: string
  url: string
  author: Partial<Committer>
  committer: Partial<Committer>
  message: string
}

const formatSignoffHtml = (committer: Partial<Committer>): string =>
  formatSignoff(committer)
    .replace('<', '&lt;')
    .replace('>', '&gt;')
    .replace(/^"/, '')
    .replace(/"$/, '')

const formatSignoff = ({ email, name }: Partial<Committer>): string =>
  `"${name ?? 'MISSING NAME'} <${email}>"`

const getDCOStatus = (commits: Commits, url: string): DCOFailed[] => {
  const failed = []

  for (const { commit, author, parents, sha } of commits) {
    if (parents && parents.length > 1) {
      continue
    }

    if (author?.type === 'Bot') {
      continue
    }

    const info: DCOFailed = {
      sha,
      url: `${url}/commits/${sha}`,
      author: { email: commit?.author?.email, name: commit?.author?.name },
      committer: { email: commit?.committer?.email, name: commit?.committer?.name },
      message: '',
    }

    const signoffs = getSignoffs(commit)

    if (signoffs.length === 0) {
      info.message = 'No Signed-off-by trailer found.'
      failed.push(info)
      continue
    }

    const email = info.author.email ?? info.committer.email

    if (!email) {
      info.message = 'Cannot find email for commit author or committer'
      failed.push(info)
      continue
    }

    if (!validator.validate(email)) {
      info.message = `${email} does not look like a valid email address.`
      failed.push(info)
      continue
    }

    const name = info.author.name ?? info.committer.name

    if (!name) {
      info.message = `Cannot find name for commit author or committer`
      failed.push(info)
      continue
    }

    const commitAuthor = info.author as Committer
    const commitCommitter = info.committer as Committer

    const expected =
      commitAuthor.name === commitCommitter.name &&
      commitAuthor.email === commitCommitter.email
        ? formatSignoff(commitAuthor)
        : `${formatSignoff(commitAuthor)} or ${formatSignoff(commitCommitter)}`

    const authors = [commitAuthor.name.toLowerCase(), commitCommitter.name.toLowerCase()]
    const emails = [commitAuthor.email.toLowerCase(), commitCommitter.email.toLowerCase()]

    const valid = signoffs.filter(
      ({ name: signoffName, email: signoffEmail }) =>
        authors.includes(signoffName.toLowerCase()) &&
        emails.includes(signoffEmail.toLowerCase()),
    )

    if (valid.length === 0) {
      const got = signoffs.map((identity) => formatSignoff(identity)).join(', ')

      info.message =
        signoffs.length === 1
          ? `Expected ${expected}, but got ${got}.`
          : `Cannot find ${expected} in sign-offs: ${got}.`

      failed.push(info)
    }
  }

  return failed
}

const signoffRE = /^Signed-off-by: (.*) <(.*)>$/gim

const getSignoffs = ({ message }: { message: string }): Committer[] => {
  const matches = []
  let match

  while ((match = signoffRE.exec(message)) !== null) {
    matches.push({ name: match[1], email: match[2] })
  }

  return matches
}

const failedSha = (details: DCOFailed | DCOFailed[]): string => {
  if (Array.isArray(details)) {
    return `${failedSha(details[0])}..${failedSha(details[details.length - 1])}`
  }

  return details.sha.slice(0, 7)
}

const buildMessage = (commitLength: number, dcoFailed: DCOFailed[]): string =>
  commitLength === 1 || dcoFailed.length === 1
    ? `Commit ${failedSha(dcoFailed[0])} is incorrectly signed off.`
    : dcoFailed.length === commitLength
    ? `All commits (${failedSha(dcoFailed)}) are incorrectly signed off.`
    : `${dcoFailed.length} commits in ${failedSha(dcoFailed)} are incorrectly signed off.`

async function run(): Promise<void> {
  const repoToken = core.getInput('repo-token')
  const client = github.getOctokit(repoToken)

  if (!github.context.payload.pull_request) {
    throw new Error(
      'This can only be run in a pull_request or pull_request_target context.',
    )
  }

  const base = github.context.payload.pull_request.base.sha
  const head = github.context.payload.pull_request.head.sha

  const result = await client.rest.repos.compareCommitsWithBasehead({
    owner: github.context.repo.owner,
    repo: github.context.repo.repo,
    basehead: `${base}...${head}`,
  })

  if (!result) {
    throw new Error(`cannot get commits ${base}...${head} - not found.`)
  }

  if (result.status !== 200) {
    throw new Error(`cannot get commits ${base}...${head} - ${result.status}.`)
  }

  const commits = result.data.commits
  const dcoFailed = getDCOStatus(
    commits,
    github.context.payload.pull_request.html_url ?? '',
  )

  if (dcoFailed.length > 0) {
    await core.summary
      .addHeading('Failed DCO Results')
      .addTable([
        [
          { data: 'Commit', header: true },
          { data: 'Author', header: true },
          { data: 'Committer', header: true },
          { data: 'Reason', header: true },
        ],
        ...dcoFailed.map(({ author, committer, message, sha, url }) => [
          `<a href="${url}"><code>${sha.slice(0, 7)}</code></a>`,
          formatSignoffHtml(author),
          formatSignoffHtml(committer),
          message,
        ]),
      ])
      .write()

    throw new Error(buildMessage(commits.length, dcoFailed))
  } else {
    await core.summary.addHeading('DCO Passed').write()
  }
}

run()
  // eslint-disable-next-line github/no-then
  .then(() => process.exit())
  // eslint-disable-next-line github/no-then
  .catch((error) => core.setFailed(error.message))
