# Profile gallery

A community gallery where users share Dock profiles and install other people's profiles in one click. Ships in **v0.4+**, after profiles, missing-app detection, and JSON import/export exist.

## Approach: GitHub repo as registry

- A public repo (e.g. `oh-my-dock/gallery`) holds one JSON file per profile plus preview metadata.
- **Submit**: "Share profile" in the app exports the JSON and opens a pre-filled PR (or the user opens one manually).
- **Validate**: CI checks every PR against the profile JSON schema, rejects unknown fields, and lints URLs.
- **Moderate**: maintainers review and merge PRs.
- **Publish**: CI builds a static `index.json` (name, author, category, tags, item list, preview) and deploys it to GitHub Pages.
- **Browse**: the app's **Gallery** tab fetches `index.json`. It offers categories (Dev, Design, Students, Streaming, Minimal…), search, and a rendered Dock preview.
- **Install**: one click copies the profile locally as a normal, editable profile.

Cost: free. Needs a GitHub account to submit, not to browse.

## Link sharing

Also supported, with no gallery needed:

- `ohmydock://import?url=<https-url-to-profile.json>`
- Import from a file or a gist URL.

The same validation and safety rules apply.

## Portability

Profiles reference apps that may not be installed, or may live at different paths. Each item stores stable identifiers:

```json
{
  "type": "app",
  "name": "Figma",
  "bundleId": "com.figma.Desktop",
  "brewCask": "figma",
  "appStoreId": null,
  "path": "/Applications/Figma.app"
}
```

On install, apps are resolved by bundle ID, so `path` is only a hint. Missing apps are listed, for example: "4 of 6 apps installed — install missing: `brew install --cask figma slack`".

## Security rules

Shared profiles are untrusted input. A malicious profile could add phishing URLs, open folders, or quit apps.

- Imported profiles **never** carry quit/launch-on-switch settings or triggers. These always start **off** and must be enabled by the user locally.
- Before install, show **every URL and folder** in the profile. URLs must be `https`. Folders must be inside the user's home and are shown with their full path.
- **No scripts or shell commands**, ever. The schema has no field for them.
- Strict schema validation: unknown fields are rejected, and the file size is capped.
- Dock preferences in shared profiles are shown as a diff and applied only on confirm.
- A "Report profile" link opens a GitHub issue.

## Later (only if the gallery takes off)

- Web gallery with accounts, in-app upload, likes, and download counts. This requires a backend, auth, and moderation tooling.
