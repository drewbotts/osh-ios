# Releasing to TestFlight

Everything needed to get a build in front of testers, and the small number of
things that are easy to get wrong and cost a day each.

---

## Before the first upload ever

These are one-time, and none of them can be done from this repository — see
*Outside the repo* at the end for the full checklist. In short: the two App IDs
must exist, and the app record must exist in App Store Connect.

---

## Versions

| Field | Where it comes from | Value today |
|---|---|---|
| Version (`CFBundleShortVersionString`) | `MARKETING_VERSION`, set per target | `0.9.1` |
| Build (`CFBundleVersion`) | `scripts/stamp-build-version.sh`, from `git rev-list --count HEAD` | the commit count |

**The build number is never edited by hand.** A last build phase on both the app
and the widget extension rewrites the built `Info.plist` from the commit count.
Two consequences worth knowing:

- **Commit before you archive.** The build number is the commit count, so an
  archive made with uncommitted work carries the previous commit's number. If
  that number is already uploaded, App Store Connect rejects the upload.
- **Never rewrite history between uploads.** A rebase that drops commits lowers
  the count, and a build number must increase.

The script also restates `CFBundleShortVersionString` from `MARKETING_VERSION`,
so the app and the extension always agree on both fields. **App Store Connect
rejects an upload whose extension version does not match its app's**, and that
is the failure this prevents. If you bump the version, bump it on *all* targets
(there is one `MARKETING_VERSION` per configuration per target — eight in
total), or the script will happily stamp a mismatch.

### Version bump policy

`MAJOR.MINOR.PATCH`, and while the app is pre-1.0 the minor number carries the
weight:

- **Patch** (`0.9.0` → `0.9.1`) — fixes only, no new surface. Most TestFlight
  builds inside a testing round.
- **Minor** (`0.9.0` → `0.10.0`) — a development pass landing: a new tab, a new
  datastream role, a new capability testers should be told about.
- **Major** (`1.0.0`) — reserved for the first public release.

Re-uploading after a rejection needs no version change, only a new commit, since
the build number moves on its own.

---

## Archiving and uploading

```sh
# 1. Commit. The build number is the commit count.
git status --porcelain          # must be empty

# 2. Tests, from the fixtures, no network.
xcodebuild test -scheme osh-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# 3. Archive.
xcodebuild archive -scheme osh-ios \
  -destination 'generic/platform=iOS' \
  -archivePath build/osh-ios.xcarchive \
  -allowProvisioningUpdates

# 4. Confirm what is actually in the archive before uploading.
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  build/osh-ios.xcarchive/Products/Applications/osh-ios.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  build/osh-ios.xcarchive/Products/Applications/osh-ios.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  build/osh-ios.xcarchive/Products/Applications/osh-ios.app/PlugIns/OSHiOSWidgets.appex/Info.plist
# the last two must be equal
```

Then either open the archive in Xcode's Organizer and **Distribute App → App
Store Connect → Upload**, or export and upload from the command line:

```sh
xcodebuild -exportArchive \
  -archivePath build/osh-ios.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist docs/ExportOptions.plist \
  -allowProvisioningUpdates

xcrun altool --upload-app -f build/export/osh-ios.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

`docs/ExportOptions.plist` does not exist yet — the Organizer route needs no
such file, and the values (`method: app-store-connect`, `teamID: 8B548M8H4W`)
depend on choices nobody has made yet. Write it when the upload is automated.

Processing takes 5–30 minutes. Export compliance is answered already —
`ITSAppUsesNonExemptEncryption` is `false` in the app's `Info.plist`, because the
app uses only the system's own TLS — so no questionnaire appears.

---

## The 90-day expiry

**A TestFlight build stops launching 90 days after it is uploaded.** Not 90 days
after a tester installs it; 90 days from upload. The build disappears from
TestFlight and testers get "This beta has expired".

What that means in practice:

- Upload a fresh build at least every ~80 days if testing is ongoing, even when
  nothing has changed. A build with no changes still needs a new commit for the
  build number to move; an empty commit (`git commit --allow-empty`) is enough.
- The expiry is per build, so a tester on an older build can be expired while
  another is not.
- Internal testers (up to 100, on your team) need no review. External testers
  (up to 10,000, by group or public link) need Beta App Review on the first
  build of a version — subsequent builds of the same version usually pass
  without another review.

---

## What to Test

Paste into App Store Connect → TestFlight → the build → **What to Test**.

> OSH iOS turns an iPhone into a sensor for an OpenSensorHub node, and a viewer
> for everything else on that node. It publishes GPS, orientation, barometric
> pressure, sound level and video as OGC Connected Systems datastreams, and it
> reads back and draws every other system the node holds.
>
> **Permissions it asks for, and why**
> - **Location** — the GPS feed. Recording continues while the screen is locked,
>   so a field session is not cut short; this is the point of the app, so please
>   allow it.
> - **Camera** — the video feed, and the camera preview tile on the Video tab.
> - **Microphone** — the ambient sound-level feed. A loudness figure only; no
>   audio is recorded or saved anywhere.
> - **Motion** — device orientation and barometric altitude.
> - **Local network** — nodes are usually on the same Wi-Fi, reached by IP.
>   Denying this makes every connection to a LAN node fail.
>
> Nothing is sent anywhere except the server you configure. There is no
> analytics, no account, and no data collected by us.
>
> **Add a server first — nothing works without one**
> 1. **Settings → Servers → +**
> 2. Label it, and enter the base API URL, including the path:
>    `http://192.168.1.50:8181/sensorhub/api`
> 3. Username and password are optional — leave both blank for an open node.
> 4. **Trust server certificate (self-signed)** — leave this off unless the node
>    is `https://` and its certificate is one you issued yourself, which is
>    normal for an OSH box on a private network. With it off, such a node fails
>    with "Certificate not trusted"; with it on, the certificate is accepted for
>    that server's host only. Plain `http://` nodes do not need it.
> 5. **Test Connection**. A green check means the node answered and accepted the
>    credentials. Fix this before going further; a red result here explains
>    every empty screen that follows — it now names the actual cause, whether
>    that is an untrusted certificate, a redirect to a different URL, or a
>    server that cannot be reached at all.
> 6. Go to **Systems** and select the server in the picker at the top.
>
> **Live** — this device as a sensor. Toggle the sensors you want in Settings,
> then **Start Streaming**. Each enabled sensor gets a card with its current
> reading and a sent / error count. Check that: values update at a sensible
> rate; the counters climb and the error count stays at zero; the Live Activity
> appears on the lock screen; and GPS keeps counting up after you lock the phone
> for a few minutes.
>
> **Map** — one map with everything on it. Your own track and fix are drawn
> beside every system on the node that says where it is. Check that: your marker
> appears and follows you when tapped; node systems appear with the right icons;
> a direction finder draws an orange line of bearing; a laser range finder draws
> a red crosshair with a line back to the phone that observed it; and the layers
> menu (top right) turns each of those on and off. Markers that crowd together
> should group into a numbered bubble and separate again as you zoom.
>
> **Video** — every camera on the node at once, plus this device's preview as
> the first tile. Check that: tiles start playing on Wi-Fi; at most four play at
> once and tapping a fifth pauses the longest-running one; tapping a tile opens
> it full screen; and a camera with pan/tilt support shows a D-pad over the
> picture that actually moves it.
>
> **Systems** — the list of everything. Check that: every system on the node is
> listed with an activity dot (green under 5 minutes old, amber under 30, red
> beyond); the filters (Live only / With position / With video / With controls)
> narrow it correctly; and opening a row gives a dashboard whose cards match
> what the system actually is — a map for a position, a dial for a bearing, a
> waterfall for a spectrum, rows of values for anything else.
>
> **Most useful things to report**: a system that draws as the wrong kind of
> thing, a datastream that says "schema not understood", a marker in the wrong
> place, and anything on the **Logs** tab marked error. Logs can be copied out
> from that tab — please include them.

---

## Outside the repo

Nothing below can be changed from this repository.

**Apple Developer portal — Identifiers.** Two App IDs, and the extension's must
be a child of the app's:

| | |
|---|---|
| App | `org.opensensorhub.oshios` |
| Widget extension | `org.opensensorhub.oshios.OSHiOSWidgets` |

The extension's id **must** stay a prefix-child of the app's: renaming one
without the other orphans the extension and the upload is rejected.

Both are registered to team `8B548M8H4W`, and both targets use automatic
signing, so Xcode maintains the profiles. The ids changed from
`org.opensensorhub.osh-ios*` before the first upload, so the two older App IDs
in the portal are unused and can be deleted once nothing references them. No special capabilities are needed —
background location and Live Activities are `Info.plist` declarations, not
entitlements.

**App Store Connect — the app record.** Must exist before the first upload,
created against `org.opensensorhub.oshios`, with a name, primary language, and
a category. An upload against a bundle ID with no app record is rejected.

**App Store Connect — App Privacy.** A questionnaire separate from the bundled
`PrivacyInfo.xcprivacy`, and required before external testing. The answers match
the manifest: no data collected, no tracking. Location, camera and microphone
data are used by the app but not collected by the developer — they go only to the
user's own server — which is "Data Not Collected".

**Team invites.** Internal testers must be members of team `8B548M8H4W` with a
role that has TestFlight access. External testers need a group and, on the first
build of each version, Beta App Review.

---

## Notes on the build configuration

Things a future change might trip over:

- **`ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app and widget targets only.**
  The version-stamping script reads `.git` and writes the built `Info.plist`,
  and the sandbox denies both. It stays `YES` at the project level, so the test
  targets keep it. Without this the script silently stamps nothing —
  `stamp-build-version.sh` reads every write back and fails the build rather
  than let that happen quietly.
- **`PrivacyInfo.xcprivacy` is one file in two Resources phases**, the app's and
  the extension's. Each bundle is validated separately and an extension without
  a manifest fails on upload. If a required-reason API is added — a file
  timestamp, disk space, an active keyboard — declare it there; the upload will
  succeed and the review will not.
- **The app icon must have no alpha channel.** All three 1024×1024 variants are
  RGB. An alpha channel, even a fully opaque one, is rejected as ITMS-90717.
- **Both plists carry keys with no `INFOPLIST_KEY_` alias.** `UIBackgroundModes`,
  `NSLocalNetworkUsageDescription` and `ITSAppUsesNonExemptEncryption` live in
  `osh-ios-Info.plist`; the last of those has to be a real boolean, which a
  build setting cannot produce.
