# fork-sync

Keeps every fork in the [NecroArchive](https://github.com/NecroArchive) org archived from its upstream, every 6 hours.

For each fork, [`scripts/sync-refs.sh`](scripts/sync-refs.sh):

| Upstream does… | The archive… |
|---|---|
| Pushes new commits | fast-forwards the branch |
| Adds a branch or tag | copies it (bot branches like `dependabot/` are skipped) |
| Force-pushes / rewrites a branch, or moves a tag | keeps the old state as `name@archived-<timestamp>`, then follows upstream |
| Deletes a branch or tag | keeps it |
| Deletes the repo or makes it private | keeps the fork untouched |

## Setup

- Secret **`SYNC_TOKEN`**: classic personal access token with `repo` and `workflow` scopes.
- Runs on a schedule (`0 */6 * * *`, UTC) or manually from the Actions tab, where **dry run** only reports what would change.

Run locally (uses your `gh` login):

```sh
ORG=NecroArchive DRY_RUN=true bash scripts/sync-refs.sh
ORG=NecroArchive DRY_RUN=true REPOS="NecroArchive/OpenRCT2" bash scripts/sync-refs.sh
```
