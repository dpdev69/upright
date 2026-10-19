# Releasing

How to cut an Upright release, and how to make CI sign and notarize it.

The **app** job in `.github/workflows/build.yml` checks which signing secrets the repository
has:

| Secrets set | Result |
| --- | --- |
| None | Ad-hoc signed app and DMG. Gatekeeper blocks the first launch. |
| Certificate only | App and DMG signed with Developer ID, not notarized. CI warns. |
| Certificate and notary credentials | Signed, notarized and stapled DMG, checked with `stapler validate` and `spctl`. |

Setting only some of the secrets in a group fails the job, so a typo doesn't silently produce
an ad-hoc release. Secrets are never available to builds from forks, so those stay ad-hoc.

## One-time setup for notarized releases

You need a paid Apple Developer Program membership. Only the Account Holder can create a
Developer ID certificate.

### 1. Developer ID Application certificate

1. In Xcode, open **Settings > Accounts**, select the team, click **Manage Certificates**, then
   **+ > Developer ID Application**. (Or create it at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   from a certificate signing request made in Keychain Access.)
2. Open **Keychain Access**, choose the **login** keychain and **My Certificates**.
3. Right-click **Developer ID Application: <name> (<team ID>)** (it must show a private key
   under it) and choose **Export**. Save as `.p12` and set a strong password.
4. Base64-encode it and copy the result:

   ```bash
   base64 -i DeveloperIDApplication.p12 | pbcopy
   ```

5. Delete the `.p12` file once the secret is saved. Keep the certificate in your keychain or in
   a password manager; it is valid for five years.

### 2. Notary credentials

Use an App Store Connect API key (preferred):

1. In [App Store Connect](https://appstoreconnect.apple.com/), open **Users and Access >
   Integrations > App Store Connect API > Team Keys** and click **+**.
2. Name it (for example `Upright notary`) and give it the **Developer** role.
3. Download `AuthKey_<KEY ID>.p8`. Apple lets you download it only once.
4. Note the **Key ID** (in the keys table) and the **Issuer ID** (above the table).

Or, instead, an Apple ID with an app-specific password: create the password at
[account.apple.com](https://account.apple.com/) under **Sign-In and Security > App-Specific
Passwords**, and find your Team ID under **Membership details** at developer.apple.com. If both
kinds of notary credentials are set, CI uses the API key.

### 3. Repository secrets

In GitHub, open the repository's **Settings > Secrets and variables > Actions** and add each one
with **New repository secret**:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | The base64 text from step 1.4 |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `NOTARY_KEY_ID` | The API key's Key ID |
| `NOTARY_ISSUER_ID` | The Issuer ID |
| `NOTARY_KEY_P8` | The whole contents of `AuthKey_<KEY ID>.p8`, including the `BEGIN`/`END` lines (base64 of the file also works) |

For the Apple ID route, set `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` instead of the
three `NOTARY_*` secrets.

### 4. Check it before tagging

1. Open **Actions > Build > Run workflow** and run it on `main`.
2. In the **app** job log, check that:
   - **Detect signing secrets** prints `signing=true notarize=api` (or `notarize=appleid`);
   - **Notarize and staple DMG** prints `Notarization <id>: Accepted`;
   - **Check notarized DMG** shows `source=Notarized Developer ID` for the DMG and the app.
3. Optionally download the `Upright-dmg` artifact and check it locally:

   ```bash
   xcrun stapler validate Upright-*.dmg
   spctl -a -vv -t open --context context:primary-signature Upright-*.dmg
   ```

Once the secrets are set, pushes to `main` and pull requests from branches in this repository
are notarized too, which adds a few minutes to each run.

## Cutting a release

1. In `Upright.xcodeproj/project.pbxproj`, set `MARKETING_VERSION` to `X.Y.Z` and raise
   `CURRENT_PROJECT_VERSION` by one. Each appears twice (Debug and Release).
2. In `CHANGELOG.md`, move the **Unreleased** entries under `## [X.Y.Z] - YYYY-MM-DD`.
3. Merge to `main` and wait for the Build workflow to pass.
4. Tag the merge commit and push the tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   CI fails if the tag doesn't match `MARKETING_VERSION`. The **release** job attaches
   `Upright-X.Y.Z.dmg` to a GitHub release with generated notes.
5. Update the version shown on the website (`softwareVersion` and the version pill in
   `site/index.html`).
6. After the first notarized release, update the Gatekeeper wording in `README.md`,
   `INSTALL.md` and `SECURITY.md`, which currently say releases aren't notarized.

## Homebrew cask

The main Homebrew cask repository (`homebrew/cask`) expects apps to pass Gatekeeper, so an
ad-hoc signed DMG isn't a candidate. Submit a cask only after a notarized release exists. The
cask points at the release's `Upright-X.Y.Z.dmg` with its SHA-256; later versions can be bumped
with `brew bump-cask-pr`.
