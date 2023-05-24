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

type ArrayElement<ArrayType extends readonly unknown[]> =
  ArrayType extends readonly (infer ElementType)[] ? ElementType : never

type ResponseType = Endpoints['GET /repos/{owner}/{repo}/compare/{basehead}']['response']
type CommitCompare = ResponseType['data']
type Commits = CommitCompare['commits']
type Commit = ArrayElement<Commits>

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

const formatSignoff = ({ email, name }: Committer) => `"${name} <${email}>"`

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
      info.message = 'A DCO sign-off is missing'
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
      commitAuthor.email == commitCommitter.email
        ? formatSignoff(commitAuthor)
        : `${formatSignoff(commitAuthor)} or ${formatSignoff(commitCommitter)}`

    const authors = [commitAuthor.name.toLowerCase(), commitCommitter.name.toLowerCase]
    const emails = [commitAuthor.email.toLowerCase(), commitCommitter.email.toLowerCase]

    const valid = signoffs.filter(
      ({ name, email }) =>
        authors.includes(name.toLowerCase()) && emails.includes(email.toLowerCase())
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

const getSignoffs = ({ message }: { message: string }) => {
  const matches = []
  let match

  while ((match = signoffRE.exec(message)) !== null) {
    matches.push({ name: match[1], email: match[2] })
  }

  return matches
}

type PR = typeof github.context.payload.pull_request

const handleOneCommit = (pr: NonNullable<PR>) =>
  `You only have one commit incorrectly signed off! To fix, first ensure you have a local copy of your branch by [checking out the pull request locally via command line](https://help.github.com/en/github/collaborating-with-issues-and-pull-requests/checking-out-pull-requests-locally). Next, head to your local branch and run: \n\`\`\`bash\ngit commit --amend --no-edit --signoff\n\`\`\`\nNow your commits will have your sign off. Next run \n\`\`\`bash\ngit push --force-with-lease origin ${pr.head.ref}\n\`\`\``

const handleMultipleCommits = (
  pr: NonNullable<PR>,
  commitLength: number,
  dcoFailed: DCOFailed[]
) =>
  `You have ${dcoFailed.length} commits incorrectly signed off. To fix, first ensure you have a local copy of your branch by [checking out the pull request locally via command line](https://help.github.com/en/github/collaborating-with-issues-and-pull-requests/checking-out-pull-requests-locally). Next, head to your local branch and run: \n\`\`\`bash\ngit rebase HEAD~${commitLength} --signoff\n\`\`\`\n Now your commits will have your sign off. Next run \n\`\`\`bash\ngit push --force-with-lease origin ${pr.head.ref}\n\`\`\``

async function run(): Promise<void> {
  const repoToken = core.getInput('repo-token')
  const client = github.getOctokit(repoToken)

  if (!github.context.payload.pull_request) {
    throw new Error(
      'This can only be run in a pull_request or pull_request_target context.'
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

  if (result.status != 200) {
    throw new Error(`cannot get commits ${base}...${head} - ${result.status}.`)
  }

  const commits = result.data.commits
  const dcoFailed = getDCOStatus(
    commits,
    github.context.payload.pull_request.html_url ?? ''
  )

  if (dcoFailed.length > 0) {
    const summary = dcoFailed
      .map(
        (commit) =>
          `Commit sha: [${commit.sha.slice(0, 7)}](${commit.url}), Author: ${
            commit.author
          }, Committer: ${commit.committer}; ${commit.message}`
      )
      .join('\n')

    const message =
      dcoFailed.length === 1
        ? handleOneCommit(github.context.payload.pull_request)
        : handleMultipleCommits(
            github.context.payload.pull_request,
            commits.length,
            dcoFailed
          )

    throw new Error(`${message}\n\n${summary}`)
  }
}

run()
  .then(() => process.exit())
  .catch((error) => core.setFailed(error.message))
