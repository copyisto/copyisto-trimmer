# Releasing

A pushed tag such as `v0.2.0` makes GitHub Actions test, build, sign, notarise and publish the app (`.github/workflows/build.yml`), then update its Homebrew cask in [copyisto/homebrew-tap](https://github.com/copyisto/homebrew-tap).
The download link in the README always points at the latest release: `releases/latest/download/Copyisto-Trimmer.zip`.

## Why the secrets matter

Without them, the build is signed ad hoc.
macOS then refuses to open the downloaded app, and the only way past it is System Settings → Privacy & Security → **Open Anyway**.
With them, the app is signed with a Developer ID, notarised by Apple and stapled, so it opens with a double click, offline too.
The workflow signs only when `MACOS_CERTIFICATE` is set, notarises only when `NOTARY_KEY` or `NOTARY_APPLE_ID` is set as well, and updates the cask only when `HOMEBREW_TAP_KEY` is set; forks and pull requests keep building ad hoc.

## Setting the secrets

`scripts/signing.sh` makes all six from the keychain or Apple's web pages.
The Apple account does not have to be signed in on this Mac, in Xcode or anywhere else: the private key is made here, Apple's website only signs it, and the script hands everything to GitHub without printing it.
It needs `gh` signed in with admin access to copyisto/copyisto-trimmer and copyisto/homebrew-tap.

The Apple account has to be the **Account Holder** of a paid Apple Developer Program team, since only the Account Holder can make a Developer ID certificate and the first App Store Connect API key.
Sign in to the web pages below with that account.

### 1. The certificate: `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`

The **Developer ID Application** certificate with its private key, as a `.p12`.
Check whether this Mac has one, and for which team:

```sh
security find-certificate -a -c "Developer ID Application" -p | openssl x509 -noout -subject -enddate
```

**If it does**, as `Developer ID Application: Michal Kulbacki (4Y2F8384Q2)` does on Michał's Mac, export it:

1. Open Keychain Access (`open -a "Keychain Access"`) → login → **My Certificates**.
   Not Certificates: only My Certificates exports the private key along.
2. Right-click **Developer ID Application: …** → **Export** → format Personal Information Exchange (`.p12`) → save to the Desktop with a new password.
   macOS then asks for your login password to let the key out.
3. Set both secrets; the script asks for the `.p12` password and checks the file holds the certificate and its key:
   ```sh
   scripts/signing.sh p12 ~/Desktop/Certificates.p12
   ```
4. Keep the `.p12` and its password in a password manager, then delete the file.

**If it does not**, make one with Apple's web page:

1. Make a private key and a signing request, with the Apple account's email:
   ```sh
   scripts/signing.sh request dev@michalkulbacki.com
   ```
   They go to `~/copyisto-signing/`, which Finder opens.
2. [developer.apple.com → Certificates → **+**](https://developer.apple.com/account/resources/certificates/add) → **Developer ID Application** → Continue → Profile Type **G2 Sub-CA** → Choose File: `~/copyisto-signing/developer-id.csr` → Continue → **Download**.
3. Turn the downloaded certificate into the two secrets:
   ```sh
   scripts/signing.sh certificate ~/Downloads/developerID_application.cer
   ```
   It checks the certificate belongs to the key, makes a `.p12` with a random password and sets both secrets.
4. Keep `~/copyisto-signing/developer-id.p12` and `developer-id.key` in a password manager, then delete the folder.

The scripts print when the certificate expires (the one made for this repository in October 2026 runs until November 2027); renewing it is the same steps, and the build fails to sign once it has expired.
The build adds Apple's intermediate certificates itself, so a `.p12` with the certificate alone is enough.

### 2. The notary key: `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`

`notarytool` signs in with an App Store Connect API key instead of an Apple ID and an app-specific password.

1. [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
   The first time, the Account Holder presses **Request Access** and accepts the terms.
2. **Team Keys** → **+** → name `copyisto-trimmer notarisation`, access **Developer** → **Generate**.
3. **Download** the key, `AuthKey_<KEY ID>.p8`.
   Apple lets you download it once only, so keep it in a password manager too.
4. Copy the **Issuer ID** shown above the list of keys, and set the three secrets:
   ```sh
   scripts/signing.sh notary ~/Downloads/AuthKey_ABC123DEFG.p8 01234567-89ab-cdef-0123-456789abcdef
   ```
   The key ID comes from the file's name, and the script asks Apple whether the key works before setting anything.

**Without Integrations**, which App Store Connect shows only to the Account Holder and Admins, once the current agreements are accepted (Business → Agreements), notarise with the Apple ID instead:

1. [account.apple.com](https://account.apple.com) → Sign-In and Security → **App-Specific Passwords** → **+**, named `copyisto-trimmer notarisation`.
2. Set the three secrets with the Apple ID and the team ID (in brackets in the certificate's name, or under Membership details on developer.apple.com); the script asks for the password and checks it with Apple:
   ```sh
   scripts/signing.sh apple-id dev@michalkulbacki.com 4Y2F8384Q2
   ```

The build uses the API key when both are set.
An app-specific password stops working when the Apple ID's password changes; revoke it on the same page when it is no longer needed.

### 3. The Homebrew tap: `HOMEBREW_TAP_KEY`

The tap is its own repository, made once from its local copy (a `Casks/copyisto-trimmer.rb` and a README):

```sh
gh repo create copyisto/homebrew-tap --public --source ../homebrew-tap --push
scripts/signing.sh tap
```

It makes an SSH key, adds its public half to copyisto/homebrew-tap as a deploy key with write access, and sets the private half as the secret.
A deploy key reaches that one repository only and belongs to no person, so it outlives anyone's access token.

`gh secret list -R copyisto/copyisto-trimmer` should then list all six: two for the certificate, three for notarisation and the tap's key.

## Publishing a release

```sh
git tag v0.2.0
git push origin v0.2.0
```

The tag is the version Finder shows, without the `v`.
The run (GitHub → Actions → Build) takes about five minutes; notarisation can add a few more.
Its **Notarise** step ends with `spctl --assess`, which prints `accepted` and `source=Notarized Developer ID` for a good build.
The release gets the zip and notes generated from the commits since the previous tag, and the tap gets a commit `copyisto-trimmer 0.2.0` with the zip's checksum.

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
Installed with Homebrew, `brew upgrade` updates it, as it does every other cask.
Otherwise **Copyisto Trimmer → Sprawdź aktualizacje…** opens the latest release, whose zip replaces the old app in Applications.
Nothing is lost either way: the boxes and crops live in each notebook's `.trims/`, and the settings (last folder, page, format) in the app's preferences, never in the app bundle.
