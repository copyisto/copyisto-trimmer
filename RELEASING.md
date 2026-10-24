# Releasing

A pushed tag such as `v0.2.0` makes GitHub Actions test, build, sign, notarise and publish the app (`.github/workflows/build.yml`).
The download link in the README always points at the latest release: `releases/latest/download/Copyisto-Trimmer.zip`.

## Why the signing secrets matter

Without the secrets below, the build is signed ad hoc.
macOS then refuses to open the downloaded app, and the only way past it is System Settings → Privacy & Security → **Open Anyway**, or `xattr -dr com.apple.quarantine "/Applications/Copyisto Trimmer.app"`.
With them, the app is signed with a Developer ID, notarised by Apple and stapled, so it opens with a double click, offline too.
The workflow signs only when `MACOS_CERTIFICATE` is set and notarises only when `NOTARY_KEY` is set as well; forks and pull requests keep building ad hoc.

## The secrets

All five go to the repository: GitHub → copyisto/copyisto-trimmer → Settings → Secrets and variables → Actions → **New repository secret**.
Or from the terminal, with `gh secret set`, as below; `gh` reads the value from standard input, so it never lands in the shell history.

### 1. `MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PASSWORD`

The **Developer ID Application** certificate with its private key, as a base64 `.p12`.

1. Check that you have it and when it expires:
   ```sh
   security find-certificate -a -c "Developer ID Application" -p | openssl x509 -noout -subject -enddate
   ```
   If there is none, make one at [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list) → **+** → **Developer ID Application** (only the team's Account Holder can), with a signing request from Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority, and open the downloaded `.cer` to add it to the keychain.
2. Keychain Access → **My Certificates** (not Certificates: only My Certificates exports the private key along) → right-click **Developer ID Application: …** → **Export** → format `.p12`, with a new password.
3. Set both secrets and delete the file:
   ```sh
   base64 -i ~/Desktop/DeveloperID.p12 | gh secret set MACOS_CERTIFICATE -R copyisto/copyisto-trimmer
   gh secret set MACOS_CERTIFICATE_PASSWORD -R copyisto/copyisto-trimmer   # asks for the .p12 password
   rm ~/Desktop/DeveloperID.p12
   ```

### 2. `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`

An App Store Connect API key, which `notarytool` uses instead of an Apple ID and an app-specific password.

1. [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → **Team Keys** → **+**, named for example `copyisto-trimmer notarisation`, with the **Developer** role.
2. Download the key, `AuthKey_<KEY ID>.p8`.
   Apple lets you download it once only, so keep a copy in a password manager.
3. The **Key ID** is in the key's row, and the **Issuer ID** above the list of keys.
4. Set the secrets and delete the file:
   ```sh
   base64 -i ~/Downloads/AuthKey_ABC123DEFG.p8 | gh secret set NOTARY_KEY -R copyisto/copyisto-trimmer
   gh secret set NOTARY_KEY_ID -R copyisto/copyisto-trimmer --body ABC123DEFG
   gh secret set NOTARY_ISSUER_ID -R copyisto/copyisto-trimmer --body 01234567-89ab-cdef-0123-456789abcdef
   rm ~/Downloads/AuthKey_ABC123DEFG.p8
   ```

`gh secret list -R copyisto/copyisto-trimmer` should then list all five.

## Publishing a release

```sh
git tag v0.2.0
git push origin v0.2.0
```

The tag is the version Finder shows, without the `v`.
The run (GitHub → Actions → Build) takes about five minutes; notarisation can add a few more.
Its **Notarise** step ends with `spctl --assess`, which prints `accepted` and `source=Notarized Developer ID` for a good build.
The release gets the zip and notes generated from the commits since the previous tag.

To check the download as a user gets it:

```sh
cd "$(mktemp -d)"
curl -sLO https://github.com/copyisto/copyisto-trimmer/releases/latest/download/Copyisto-Trimmer.zip
ditto -x -k Copyisto-Trimmer.zip .
spctl --assess --type execute --verbose "Copyisto Trimmer.app"
xcrun stapler validate "Copyisto Trimmer.app"
```

A build that failed after the tag was pushed is fixed by deleting the tag (`git push origin :v0.2.0`, `git tag -d v0.2.0`) and its release, if one was made, then tagging the fixed commit.

## Updates

The app does not update itself: it makes no network requests and has no dependencies.
To update, download the latest zip and drag the app over the old one in Applications.
Nothing is lost: the boxes and crops live in each notebook's `.trims/`, and the settings (last folder, page, format) in the app's preferences, never in the app bundle.
