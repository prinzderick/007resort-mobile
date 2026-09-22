# Configuration

All runtime configuration is supplied at build time with `--dart-define`
(or `--dart-define-from-file`). See [`.env.example`](../.env.example).

| Define                | Required | Default                | Description                                       |
|-----------------------|----------|------------------------|---------------------------------------------------|
| `OTUEKE_API_BASE_URL` | no       | `http://10.0.2.2:5080` | Base URL of the Otueke API (without `/api/v1`).   |
| `OTUEKE_ENV`          | no       | `dev`                  | `dev`, `staging` or `production`.                 |

`10.0.2.2` is the Android emulator's alias for the host machine. On a physical
tablet use the API's address on the property network.

Device mode (attendant, supervisor, sports entrance, sports store) is **not**
configuration: it is assigned by the API through device registration.

## Secrets

dart-define values are compiled into the APK and are therefore **not secret**.
Never place API keys, passwords or tokens in them. Device credentials will be
issued by the API during registration (design pending).

## Cleartext HTTP

Only the **debug** manifest (`android/app/src/debug/AndroidManifest.xml`)
allows cleartext HTTP, for the local dev API. Release builds must reach the API
over HTTPS.

## Android release signing

Release signing keys are **never committed**. `key.properties`, `*.jks` and
`*.keystore` are git-ignored. To sign locally or in a secured release pipeline,
create `android/key.properties` from this template (values are placeholders):

```properties
storePassword=<from-secure-store>
keyPassword=<from-secure-store>
keyAlias=<alias>
storeFile=<absolute-path-to-keystore.jks>
```

Wiring `key.properties` into `android/app/build.gradle.kts` is deferred until
the release process is agreed; release builds currently use the debug key and
must not be distributed.
