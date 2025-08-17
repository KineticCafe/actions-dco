/**
 * Copyright 2023–2024 Kinetic Commerce and contributors.
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
import type { Endpoints } from '@octokit/types'
import * as emailValidator from 'email-validator'
import escapeHtml from 'escape-html'
import { name as NAME, version as VERSION } from '../package.json'

type ResponseType = Endpoints['GET /repos/{owner}/{repo}/compare/{basehead}']['response']
type CommitCompare = ResponseType['data']
type Commits = CommitCompare['commits']

type Committer = {
  email: string
  name: string
}

type DCORecord = {
  sha: string
  url: string
  author: Partial<Committer>
  committer: Partial<Committer>
  message: string
}

type DCOResult = {
  exempted: DCORecord[]
  failed: DCORecord[]
}

type Exemptions = {
  exact: string[]
  endsWith: string[]
}

const formatSignoffHtml = (committer: Partial<Committer>): string =>
  escapeHtml(formatSignoff(committer))

const formatSignoff = ({ email, name }: Partial<Committer>): string =>
  `"${name ?? 'MISSING NAME'} <${email ?? 'MISSING EMAIL'}>"`

const isAuthorExempt = (record: DCORecord, authorExemptions: Exemptions): boolean => {
  if (authorExemptions.exact.some((email) => email === record.author.email)) {
    core.debug(
      `${record.sha}: author ${record.author.email} exempt from DCO by exact match`,
    )
    return true
  }

  if (authorExemptions.endsWith.some((domain) => record.author.email?.endsWith(domain))) {
    core.debug(
      `${record.sha}: author ${record.author.email} exempt from DCO by domain match`,
    )
    return true
  }

  return false
}

const getDCOStatus = (
  commits: Commits,
  url: string,
  authorExemptions: Exemptions,
): DCOResult => {
  const result: DCOResult = { exempted: [], failed: [] }

  core.debug(
    `getDCOStatus(<${commits.length}> commits, ${url}, <${
      authorExemptions.exact.length
    }, ${authorExemptions.endsWith.length}> exemptions)`,
  )

  for (const { commit, author, parents, sha } of commits) {
    if (parents && parents.length > 1) {
      core.debug(`commit ${sha}: skipping merge commit`)
      continue
    }

    if (author?.type === 'Bot') {
      core.debug(`commit ${sha}: skipping bot commit (${author.name} ${author.email})`)
      continue
    }

    const info: DCORecord = {
      sha,
      url: `${url}/commits/${sha}`,
      author: { email: commit?.author?.email, name: commit?.author?.name },
      committer: { email: commit?.committer?.email, name: commit?.committer?.name },
      message: '',
    }

    const signoffs = getSignoffs(sha, commit)

    if (signoffs.length === 0) {
      if (isAuthorExempt(info, authorExemptions)) {
        result.exempted.push(info)
      } else {
        info.message = 'No Signed-off-by trailer found.'
        result.failed.push(info)

        core.debug(`commit ${sha}: No exemptions or Signed-off-by trailer found. Failed.`)
      }

      continue
    }

    const email = info.author.email ?? info.committer.email

    if (!email) {
      info.message = 'Cannot find email for commit author or committer'
      result.failed.push(info)

      core.debug(`commit ${sha}: ${info.message}`)

      continue
    }

    if (!emailValidator.validate(email)) {
      info.message = `${email} does not look like a valid email address.`
      result.failed.push(info)

      core.debug(`commit ${sha}: ${info.message}`)

      continue
    }

    const name = info.author.name ?? info.committer.name

    if (!name) {
      info.message = 'Cannot find name for commit author or committer'
      result.failed.push(info)

      core.debug(`commit ${sha}: ${info.message}`)

      continue
    }

    const commitAuthor = info.author as Committer
    const commitCommitter = info.committer as Committer

    const expected =
      commitAuthor.name === commitCommitter.name &&
      commitAuthor.email === commitCommitter.email
        ? `'${formatSignoff(commitAuthor)}'`
        : `'${formatSignoff(commitAuthor)}' or '${formatSignoff(commitCommitter)}'`

    const authors = [commitAuthor.name.toLowerCase(), commitCommitter.name.toLowerCase()]
    const emails = [commitAuthor.email.toLowerCase(), commitCommitter.email.toLowerCase()]

    const signoffAuthors = JSON.stringify(signoffs.map(({ name }) => name.toLowerCase()))
    const signoffEmails = JSON.stringify(signoffs.map(({ email }) => email.toLowerCase()))

    core.debug(
      `commit ${sha}: Matching authors: signoffs=${signoffAuthors} commit=${JSON.stringify(authors)}`,
    )
    core.debug(
      `commit ${sha}: Matching emails: signoffs=${signoffEmails} commit=${JSON.stringify(emails)}`,
    )

    const valid = signoffs.filter(
      ({ name: signoffName, email: signoffEmail }) =>
        authors.includes(signoffName.toLowerCase()) &&
        emails.includes(signoffEmail.toLowerCase()),
    )

    const foundSignoffs = signoffs.map((identity) => formatSignoff(identity)).join(', ')

    core.debug(`commit ${sha}: Found ${signoffs.length} signoff(s): ${foundSignoffs}`)
    core.debug(
      `commit ${sha}: Matched ${valid.length} signoffs against author or committer`,
    )
    core.debug(`commit ${sha}: ${valid.length > 0 ? 'Success' : 'Failed'}`)

    if (valid.length === 0) {
      info.message =
        signoffs.length === 1
          ? `Expected ${expected}, but got ${foundSignoffs}.`
          : `Cannot find ${expected} in sign-offs: ${foundSignoffs}.`

      result.failed.push(info)
    }
  }

  return result
}

const signoffRE = /^signed-off-by: (?<name>.*) <(?<email>.*)>$/gim

const getSignoffs = (sha: string, { message }: { message: string }): Committer[] => {
  const matches = [...message.matchAll(signoffRE)]
    .map((match) => {
      return match.groups
        ? {
            name: match.groups.name,
            email: match.groups.email,
          }
        : undefined
    })
    .filter((committer) => committer !== undefined)

  core.debug(
    `commit ${sha}: ${matches.length} sign-off(s) on commit message: ${JSON.stringify(matches)}`,
  )

  return matches
}

const formatSha = (details: DCORecord | DCORecord[]): string => {
  if (Array.isArray(details)) {
    return `${formatSha(details[0])}..${formatSha(details[details.length - 1])}`
  }

  return details.sha.slice(0, 7)
}

const buildMessage = (commitLength: number, dcoFailed: DCORecord[]): string =>
  commitLength === 1 || dcoFailed.length === 1
    ? `Commit ${formatSha(dcoFailed[0])} is incorrectly signed off.`
    : dcoFailed.length === commitLength
      ? `All commits (${formatSha(dcoFailed)}) are incorrectly signed off.`
      : `${dcoFailed.length} commits in ${formatSha(dcoFailed)} are incorrectly signed off.`

const getAuthorExemptions = (): Exemptions => {
  const exemptions = core
    .getInput('exempt-authors')
    .split(/\s+/)
    .filter((value) => Boolean(value))
  const result: Exemptions = { exact: [], endsWith: [] }

  core.info(`Exemptions: ${JSON.stringify(exemptions)}`)

  if (exemptions.length > 0) {
    for (const candidate of exemptions) {
      if (
        !candidate.includes('@') ||
        !candidate.includes('.') ||
        candidate.indexOf('@') !== candidate.lastIndexOf('@')
      ) {
        core.warning(`Ignoring invalid exemption pattern: ${candidate}`)
        continue
      }

      if (candidate.startsWith('@')) {
        if (candidate.length < 5) {
          core.warning(`Ignoring invalid exemption pattern: ${candidate}`)
        } else {
          result.endsWith.push(candidate)
        }

        continue
      }

      if (candidate.length < 6) {
        core.warning(`Ignoring invalid exemption pattern: ${candidate}`)
      } else {
        result.exact.push(candidate)
      }
    }
  }

  return result
}

async function run(): Promise<void> {
  core.info(`${NAME} ${VERSION}`)

  const repoToken = core.getInput('repo-token')
  const client = github.getOctokit(repoToken)
  const authorExemptions = getAuthorExemptions()

  if (!github.context.payload.pull_request) {
    throw new Error(
      'This can only be run in a pull_request or pull_request_target context.',
    )
  }

  const base = github.context.payload.pull_request.base.sha
  const head = github.context.payload.pull_request.head.sha
  const range = `${base}...${head}`

  core.debug(`Actions DCO Comparing ${range}`)

  const compareResult = await client.rest.repos.compareCommitsWithBasehead({
    owner: github.context.repo.owner,
    repo: github.context.repo.repo,
    basehead: `${base}...${head}`,
  })

  if (!compareResult) {
    throw new Error(`Cannot get commits ${base}...${head} - not found.`)
  }

  if (compareResult.status !== 200) {
    throw new Error(`Cannot get commits ${base}...${head} - ${compareResult.status}.`)
  }

  const commits = compareResult.data.commits as Commits
  const dcoResult = getDCOStatus(
    commits,
    github.context.payload.pull_request.html_url ?? '',
    authorExemptions,
  )

  core.summary
    .addHeading(dcoResult.failed.length === 0 ? 'DCO Check Passed' : 'DCO Check Failed')
    .addSeparator()

  if (dcoResult.failed.length > 0) {
    core.summary.addHeading('Failed DCO Results').addTable([
      [
        { data: 'Commit', header: true },
        { data: 'Author', header: true },
        { data: 'Committer', header: true },
        { data: 'Reason', header: true },
      ],
      ...dcoResult.failed.map((record) => [
        `<a href="${record.url}"><code>${formatSha(record)}</code></a>`,
        formatSignoffHtml(record.author),
        formatSignoffHtml(record.committer),
        record.message,
      ]),
    ])
  }

  if (dcoResult.exempted.length > 0) {
    core.summary.addHeading('Commits by Authors Exempt from DCO Check', 2).addTable([
      [
        { data: 'Commit', header: true },
        { data: 'Author', header: true },
        { data: 'Committer', header: true },
      ],
      ...dcoResult.exempted.map((record) => [
        `<a href="${record.url}"><code>${formatSha(record)}</code></a>`,
        formatSignoffHtml(record.author),
        formatSignoffHtml(record.committer),
      ]),
    ])
  }

  await core.summary.write()

  if (dcoResult.failed.length > 0) {
    throw new Error(buildMessage(commits.length, dcoResult.failed))
  }
}

run()
  // eslint-disable-next-line github/no-then
  .then(() => process.exit())
  // eslint-disable-next-line github/no-then
  .catch((error) => core.setFailed(error.message))
