// node --test Tools/BugPush/*.test.mjs
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import test from 'node:test'
import { apnsHost, fixMarker, notification, providerToken } from './notify-fixed.mjs'

// As `GitHubIssues.body(of:)` ends an issue (BugReportTests.bodyTellsTheWorkflowWhichPhoneToPush).
const body = 'It says --> nothing\n\n<sub>Filed by ScreenThyme</sub>\n\n<!-- screenthyme-fixed '
  + '{"body":"You reported: “It says --\\u003e nothing” Thanks for telling us!",'
  + '"phone":"abcdef00-0000-0000-0000-000000000000","report":"12345678-0000-0000-0000-000000000000",'
  + '"title":"A problem you reported is fixed"} -->'

test('reads the marker', () => {
  const marker = fixMarker(body)
  assert.equal(marker.phone, 'abcdef00-0000-0000-0000-000000000000')
  assert.equal(marker.body, 'You reported: “It says --> nothing” Thanks for telling us!')
  assert.deepEqual(notification(marker, 7), {
    aps: { alert: { title: 'A problem you reported is fixed', body: marker.body }, sound: 'default' },
    report: '12345678-0000-0000-0000-000000000000',
    issue: 7,
  })
})

test('ignores issues without a usable marker', () => {
  assert.equal(fixMarker('Filed by hand'), null)
  assert.equal(fixMarker(null), null)
  assert.equal(fixMarker('<!-- screenthyme-fixed {not json} -->'), null)
  assert.equal(fixMarker('<!-- screenthyme-fixed {"phone":"../../etc","title":"a","body":"b"} -->'), null)
})

test('signs a provider token APNs can check', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const key = privateKey.export({ type: 'pkcs8', format: 'pem' })
  const token = providerToken({ key, keyID: 'KEY123', teamID: 'TEAM456', now: 1_700_000_000_500 })
  const [head, claims, signature] = token.split('.')
  assert.deepEqual(JSON.parse(Buffer.from(head, 'base64url')), { alg: 'ES256', kid: 'KEY123' })
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'TEAM456', iat: 1_700_000_000 })
  assert.equal(Buffer.from(signature, 'base64url').length, 64)
  assert.ok(crypto.verify('sha256', Buffer.from(`${head}.${claims}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')))
})

test('development builds go to the sandbox', () => {
  assert.equal(apnsHost('development'), 'https://api.sandbox.push.apple.com')
  assert.equal(apnsHost('production'), 'https://api.push.apple.com')
})
