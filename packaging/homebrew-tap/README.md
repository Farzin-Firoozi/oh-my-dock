# homebrew-tap (oh-my-dock)

This directory is the **full contents** of the separate GitHub repository [`Farzin-Firoozi/homebrew-tap`](https://github.com/Farzin-Firoozi/homebrew-tap). The main app repo keeps it here so we can version the cask and bump workflow without coupling releases to tap repo creation.

## Publish the tap

1. Create an empty GitHub repo named `homebrew-tap` under the `Farzin-Firoozi` account (Homebrew expects `github.com/Farzin-Firoozi/homebrew-tap`).
2. Copy everything from this folder into that repo’s root (`Casks/`, `.github/`, this README).
3. Before the first public install, run the **Bump cask** workflow once with a released version (or hand-edit `version` and `sha256` in `Casks/oh-my-dock.rb` to match a published GitHub Release). The placeholder `sha256` of all zeros is intentional until the first bump.
4. Tell users to install with:

   ```sh
   brew install --cask Farzin-Firoozi/tap/oh-my-dock
   ```

5. No Apple Developer ID: the cask documents Gatekeeper workarounds and runs a `postflight` that clears the quarantine extended attribute on the installed app.

## Bump workflow (`/.github/workflows/bump.yml`)

The tap repo workflow updates `version` and `sha256` in `Casks/oh-my-dock.rb` when:

- **`repository_dispatch`** with event type `new-release` and JSON client payload `{"version":"x.y.z"}`, or
- **`workflow_dispatch`** with input `version` (`x.y.z` only).

It downloads `OhMyDock-<version>.zip` and `OhMyDock-<version>.zip.sha256` from [oh-my-dock releases](https://github.com/Farzin-Firoozi/oh-my-dock/releases), verifies the zip against the published digest, rewrites the cask, commits, and pushes using `GITHUB_TOKEN` (`permissions: contents: write`).

Version strings are validated with `^[0-9]+\.[0-9]+\.[0-9]+$` before any download or shell use; workflow inputs are passed through environment variables, not interpolated directly into scripts.

## Notify the tap from oh-my-dock (document only)

Do **not** add this step to the main `oh-my-dock` repo until you intentionally wire releases to the tap. When the release workflow exists, add a job **after** the GitHub Release (and zip + `.sha256` sidecar) is published:

1. Create a fine-grained or classic PAT stored as **`HOMEBREW_TAP_DISPATCH_TOKEN`** on `Farzin-Firoozi/oh-my-dock` with **`contents: read`** on the app repo (for the release job) and **`metadata: read` + `contents: write`** (or repo scope) on `Farzin-Firoozi/homebrew-tap` so it can trigger `repository_dispatch`. Alternatively use a GitHub App installation token with the same cross-repo access.
2. Add a workflow step similar to:

   ```yaml
   - name: Notify Homebrew tap
     if: ${{ success() }}
     uses: peter-evans/repository-dispatch@v3
     with:
       token: ${{ secrets.HOMEBREW_TAP_DISPATCH_TOKEN }}
       repository: Farzin-Firoozi/homebrew-tap
       event-type: new-release
       client-payload: '{"version":"REPLACE_WITH_RELEASE_VERSION"}'
   ```

   Set `REPLACE_WITH_RELEASE_VERSION` from the same semver the release job published (e.g. an earlier step’s `outputs.version`). Never echo the token in logs.

3. The tap’s **Bump cask** workflow runs on `new-release`, verifies the artifact, and pushes the cask update.

Manual fallback: run **Bump cask** → **Run workflow** on the tap repo and enter the version.

## Local static check

From this directory:

```sh
chmod +x test-cask.sh
./test-cask.sh
```

Runs `ruby -c` on the cask and greps for required stanzas. No Homebrew, no network, no installs.
