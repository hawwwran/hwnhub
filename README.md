# hwnhub

A self-hosted Flatpak channel for `hawwwran`'s apps. Think of it as a tiny private
Flathub: install one app from here and the rest show up in GNOME Software's search
automatically.

- Channel URL: <https://hawwwran.github.io/hwnhub/>
- Apps currently in the channel are listed on that page; each has a `.flatpakref`
  next to it.

## Layout

This repo carries the **tooling** on `main` and the **served Flatpak repo** on
`gh-pages`. Two distinct things, one project:

| Branch     | Contents                                                            | Who reads it          |
|------------|---------------------------------------------------------------------|-----------------------|
| `main`     | `publish.sh`, templates, this README                                | Release scripts       |
| `gh-pages` | OSTree repo, per-app `.flatpakref`, `index.html`, public GPG key    | End users via Pages   |

## Installing an app from this channel

End-user flow — no setup required:

```bash
flatpak install https://hawwwran.github.io/hwnhub/io.github.hawwwran.flatpal.flatpakref
```

That adds the `hwnhub` remote on first install. After that, `flatpak update` and
GNOME Software pick up new releases automatically, and any other app published
here appears in search.

## Publishing a new release

Run `./publish.sh` from a clone of `main`. It expects a checked-out app source
tree, a manifest, and a GPG key ID. It builds the Flatpak, signs it, updates the
`gh-pages` branch, and pushes.

```
./publish.sh \
  --source-dir /path/to/app/checkout \
  --manifest io.github.hawwwran.flatpal.dev.yaml \
  --app-id io.github.hawwwran.flatpal \
  --app-name "Flatpal" \
  --version 0.2.1 \
  --gpg-key <KEYID>
```

In practice this is invoked by each app's `release-*.sh` script, not by hand.

## One-time setup: GPG key

The repo is signed so users get update-time tamper detection. Generate once,
keep the secret offline:

```bash
gpg --quick-gen-key 'hwnhub <hwnhub@hawwwran.dev>' rsa4096 sign 5y
gpg --list-keys --keyid-format LONG hwnhub
# note the long key ID (16 hex chars after `rsa4096/`)
```

Export the public key into the served repo on first publish — `publish.sh`
handles this. Back the secret key up separately; if it's lost, the channel has
to be re-keyed and all users have to re-add the remote.

## How updates reach users

1. `publish.sh` rebuilds the OSTree repo on `gh-pages` with the new commit.
2. `flatpak build-update-repo` regenerates `summary` + `appstream2/` so GNOME
   Software's metadata fetcher sees the new version.
3. The user's machine refreshes the AppStream catalog (GNOME Software does this
   on its normal cadence; CLI users hit it with `flatpak update --appstream`).
4. The update appears in the Updates view, alongside Flathub updates.

No per-update user action. Same UX as Flathub.
