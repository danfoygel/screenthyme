// Tells the phone that filed a bug report that it's fixed (PLAN.md §18), when its issue is closed as completed.
// Runs in the family's private bug repository (see README.md): the issue's hidden `screenthyme-fixed` marker names
// the phone and the words, the phone's `phones/<id>.json` holds its APNs device token, and the push goes straight to
// Apple, so the app needn't be running. Node 20+, no dependencies.

import crypto from 'node:crypto'
import { readFile } from 'node:fs/promises'
import http2 from 'node:http2'
import { pathToFileURL } from 'node:url'

const markerPattern = /<!-- screenthyme-fixed (\{.*?\}) -->/s

/** The marker ScreenThyme puts at the end of an issue it files (`GitHubIssues.fixMarker`), or null. */
export function fixMarker(body) {
  const match = markerPattern.exec(body ?? '')
  if (!match) return null
  try {
    const marker = JSON.parse(match[1])
    return /^[0-9a-f-]{36}$/.test(marker.phone) && marker.title && marker.body ? marker : null
  } catch {
    return null
  }
}

/** APNs' provider token: ES256, signed with the team's APNs key (a .p8). */
export function providerToken({ key, keyID, teamID, now = Date.now() }) {
  const encode = (object) => Buffer.from(JSON.stringify(object)).toString('base64url')
  const signed = `${encode({ alg: 'ES256', kid: keyID })}.${encode({ iss: teamID, iat: Math.floor(now / 1000) })}`
  const signature = crypto.sign('sha256', Buffer.from(signed), { key, dsaEncoding: 'ieee-p1363' })
  return `${signed}.${signature.toString('base64url')}`
}

export function notification(marker, issueNumber) {
  return {
    aps: { alert: { title: marker.title, body: marker.body }, sound: 'default' },
    report: marker.report,
    issue: issueNumber,
  }
}

export function apnsHost(environment) {
  return environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com'
}

/** Sends one push. Resolves to APNs' status and reason. */
export function push({ phone, payload, token, id }) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(apnsHost(phone.environment))
    client.on('error', reject)
    const request = client.request({
      ':method': 'POST',
      ':path': `/3/device/${phone.token}`,
      authorization: `bearer ${token}`,
      'apns-topic': phone.topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-collapse-id': id,
      'content-type': 'application/json',
    })
    let status = 0
    let body = ''
    request.on('response', (headers) => { status = headers[':status'] })
    request.setEncoding('utf8')
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      client.close()
      resolve({ status, reason: body ? JSON.parse(body).reason : undefined })
    })
    request.on('error', (error) => { client.close(); reject(error) })
    request.end(JSON.stringify(payload))
  })
}

async function phoneFile(repository, phoneID, githubToken) {
  const response = await fetch(`https://api.github.com/repos/${repository}/contents/phones/${phoneID}.json`, {
    headers: {
      authorization: `Bearer ${githubToken}`,
      accept: 'application/vnd.github.raw+json',
      'x-github-api-version': '2022-11-28',
    },
  })
  if (response.status === 404) return null
  if (!response.ok) throw new Error(`GitHub ${response.status} for phones/${phoneID}.json`)
  return response.json()
}

async function main() {
  const env = process.env
  const event = JSON.parse(await readFile(env.GITHUB_EVENT_PATH, 'utf8'))
  const issue = event.issue
  if (issue?.state_reason !== 'completed') return console.log('Not closed as completed: nothing to send.')
  const marker = fixMarker(issue.body)
  if (!marker) return console.log(`Issue #${issue.number} wasn't filed by a phone that can be told.`)
  const phone = await phoneFile(env.GITHUB_REPOSITORY, marker.phone, env.GITHUB_TOKEN)
  if (!phone) return console.log(`No push token for phone ${marker.phone.slice(0, 8)} yet.`)
  for (const name of ['APNS_KEY', 'APNS_KEY_ID', 'APNS_TEAM_ID']) {
    if (!env[name]) throw new Error(`The ${name} secret isn't set.`)
  }
  const token = providerToken({ key: env.APNS_KEY, keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID })
  const result = await push({ phone, payload: notification(marker, issue.number), token, id: `fixed-${issue.number}` })
  if (result.status === 200) return console.log(`Told phone ${marker.phone.slice(0, 8)} about issue #${issue.number}.`)
  // 410: the app was deleted, or the token is stale; the phone saves its new one when it next syncs.
  const message = `APNs ${result.status}: ${result.reason ?? 'no reason given'}`
  if (result.status === 410) return console.log(message)
  throw new Error(message)
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message)
    process.exit(1)
  })
}
