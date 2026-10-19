# Publishing BiblioJules on the Google Play Store

The APKs `flutter run` and `flutter build apk` produce are for a phone you
already hold. The Store wants a different artifact, signed with a key of your
own, and it wants a page of metadata around it. This file is that path.

---

## The signing key first

`android/app/build.gradle.kts` signs release builds with a keystore under
`android/keys/`:

```
android/keys/
├── upload-keystore.p12    # the signing material
└── keystore.properties    # its passwords and the key name
```

That directory is in `mobile/.gitignore` — the key is a credential, not source,
so it is generated once per app and never committed. `keystore.properties` holds:

```properties
keystore.password=…
signing.key.password=…
signing.key.name=bibliojules
```

Generate the keystore (`keytool` ships with the Java tools the Android SDK
installs):

```bash
mkdir -p android/keys
keytool -genkeypair -v \
    -keystore android/keys/upload-keystore.p12 \
    -storetype PKCS12 \
    -alias bibliojules \
    -keyalg RSA -keysize 2048 -validity 3650 \
    -dname "CN=BiblioJules"
```

`-alias` must be the same as `signing.key.name` in `keystore.properties`. A
PKCS12 keystore uses one password for the store and the key, so give
`keystore.password` and `signing.key.password` the same value. The `-dname` is
only a label; what has to match the app is the `applicationId` in
`android/app/build.gradle.kts`.

This key is the **upload** key. The Console runs Play App Signing on top: it
holds its own app signing key, signs what it serves, and lets you reset the
upload key if it is ever lost. Nothing here needs to know that key.

The debug certificate the Flutter template ships with is rejected outright —
Play knows it, every template app has shipped with it, and reusing it makes an
imposter indistinguishable.

---

## The bundle

```bash
cd mobile
./scripts/release.sh              # clean, resolve, build, report
```

That runs `flutter build appbundle --release --obfuscate --split-debug-info=build/symbols`
and leaves the artifact at:

```
build/app/outputs/bundle/release/app-release.aab
```

`--obfuscate` scrambles the Dart identifiers on top of the R8 minification
Flutter already does; `--split-debug-info` writes the maps that read a scrambled
stack trace back, and they stay on your machine (`build/` is ignored).

Hand the same `.aab` to nothing else: a bundle is a publishing format, not an
installable one. For a phone off the Store, `./scripts/release.sh --apk` also
builds the split APKs the README describes.

| | Bundle (`.aab`) | APK |
| --- | --- | --- |
| Goes to | the Play Console | a phone, another store |
| Architectures | all three in one file, Play splits them | one per ABI, `--split-per-abi` |
| Signed by | your upload key, then Play | your upload key alone |

`--split-per-abi` has no meaning for a bundle — the splitting is Play's job, and
that is why the bundle needs no ABI version bump in `versionCode`.

---

## Versions and build numbers

`pubspec.yaml` carries `version: 0.1.0+1`. The part after the `+` is the **build
number**, and the Console refuses an upload whose number is not higher than the
release before it:

```
0.1.0+1  →  first upload
0.1.0+2  →  second, whatever changed
0.1.1+3  →  a real change of version
```

`scripts/release.sh` prints the number it is about to build, so a refused
upload is a matter of bumping `pubspec.yaml` and running it again.

---

## What the Console wants

Upload to an **internal test track** first: the artifact is checked against the
same rules either way, and a test track does not put a listing in front of
anyone.

| Requirement | What it is here |
| --- | --- |
| App name | `BiblioJules`, as `android:label` in `android/app/src/main/AndroidManifest.xml` |
| Package name | `com.bibliojules.mobile`, from `applicationId` in `android/app/build.gradle.kts` — **fixed at the first upload**, it can never change, and a different one means a different app |
| Description, screenshots | Screenshots of the real app: sign-in, catalog, dashboard, book detail, Discover, Settings |
| Privacy policy URL | Required for any listing, hosted and public |
| Data safety | What the app collects, declared by hand: nothing by itself |
| Device access | `android.permission.CAMERA` needs a declared reason — the ISBN barcode scan; `android.permission.INTERNET` needs none |
| Pricing, ads | Free, no ads |

The Console also runs its own checks on the artifact — API level, the icon set
under `android/app/src/main/res/mipmap-*`, the `AndroidManifest.xml` — and says
what it rejects.

### HTTPS

The release manifest sets `android:usesCleartextTraffic="false"`, so a published
build refuses a plain-HTTP server: the `http://10.0.2.2:8000` the sign-in screen
suggests works only in a debug build. A listing needs the server behind HTTPS.

### Account deletion

The Console requires a way to delete an account for any app that offers sign-in.
BiblioJules runs no service of its own — see the statement in `README.md` — so
the answer is your server's, and the Console wants it spelled out: a URL, or a
step in the app.

---

## Uploading

The Console's *Releases and versions* page takes the `.aab` by hand, which is
enough for one release. For repeated ones, the Developer API drives the same
upload from a service-account credential; that is a later step, not a first one.

## When a release goes wrong

| Symptom | Cause |
| --- | --- |
| Console rejects the signature | The debug certificate, or a `signingConfig` that never got changed |
| Console rejects the build number | `pubspec.yaml` was not bumped |
| Black screen, release only | R8 renamed a class a plugin reaches by name; `android/app/proguard-rules.pro` holds those keeps |
| Icons vanish after `--obfuscate` | Add `--no-tree-shake-icons` to the build |
| A server is refused | Plain HTTP against `usesCleartextTraffic="false"` |
