# Akeyless Static Secrets Migration Script

Bash script to move Akeyless static secrets from a staging/holding path to their final application destination paths, **preserving all secret versions**.

## Problem

After migrating namespace secrets into Akeyless, all secrets land under a flat staging path:

```
/staging/<env>/<application_name>/<secret_key>
```

They need to be reorganized into the standard application path structure:

```
/<env>/<application_name>/static-secrets/<secret_key>
```

This script automates that move for all environments and applications in a single run.

## How It Works

The script uses two strategies per application folder, chosen automatically:

### Fast path: `move-objects` (preferred)

When the target folder does **not** already exist, the script uses the Akeyless `move-objects` API. This is a single API call per app that preserves all secret versions, metadata, and tags natively.

### Fallback: version-aware per-item copy

When the target folder **already exists** (e.g. from a previous partial run), `move-objects` would incorrectly nest the source folder inside the target. The script detects this and falls back to per-item migration:

1. Reads every version of the secret (`--version 1`, `--version 2`, ..., `--version N`)
2. Creates the secret at the destination with version 1
3. Adds versions 2..N using `update-secret-val --keep-prev-version true`
4. Deletes the source secret

If a create fails, the source is not deleted — no data loss is possible.

## Path Transformation

```
Source:  <source>/<env>/<app>/*
Target:  <target-prefix>/<env>/<app>/static-secrets/*
```

| Component | Description | Example |
|-----------|-------------|---------|
| `<source>` | The staging/holding folder passed via `--source` | `/staging` |
| `<target-prefix>` | Optional base path for destination, passed via `--target-prefix` | `` (empty) or `/my-org` |
| `<env>` | Environment name, from `--envs` | `dev`, `qa`, `preprod`, `prod` |
| `<app>` | Application folder name (auto-discovered) | `1015-bom-portal` |

### Example

```
Before:  /staging/prod/1015-bom-portal/db-password  (3 versions)
After:   /prod/1015-bom-portal/static-secrets/db-password  (3 versions preserved)
```

## Prerequisites

- **Akeyless CLI** installed and in `PATH` ([install guide](https://docs.akeyless.io/docs/cli))
- **Authenticated session** — run `akeyless configure` or set a profile/token before using the script
- **Python 3** — used internally for recursive folder listing
- **Permissions** — the authenticated identity must have `read`, `create`, `list`, and `delete` on the relevant paths

## Installation

```bash
chmod +x migrate-staging-secrets.sh
```

## Usage

```bash
./migrate-staging-secrets.sh --source <path> --envs <env1,env2,...> [OPTIONS]
```

### Required Arguments

| Argument | Description |
|----------|-------------|
| `--source <path>` | Akeyless folder containing the env subfolders (e.g. `/staging`) |
| `--envs <env1,env2,...>` | Comma-separated list of environment names to process |

### Optional Arguments

| Argument | Description |
|----------|-------------|
| `--target-prefix <path>` | Base path prepended to destination (default: empty) |
| `--dry-run` | Preview all moves without executing anything |
| `--app <name>` | Migrate only a specific application |
| `--help` | Show usage information |

## Examples

### Preview all environments (recommended first step)

```bash
./migrate-staging-secrets.sh \
    --source /staging \
    --envs dev,qa,preprod,prod \
    --dry-run
```

Output:

```
[INFO]  === Akeyless Static Secrets Migration ===
[INFO]  Source:  /staging/<env>/<app>/*
[INFO]  Target:  /<env>/<app>/static-secrets/*
[INFO]  Envs:    dev qa preprod prod
[WARN]  DRY-RUN MODE

[INFO]  Environment: dev
[INFO]    1015-bom-portal
[WARN]      api-key (2 ver) → /dev/1015-bom-portal/static-secrets/api-key
[WARN]      db-password (3 ver) → /dev/1015-bom-portal/static-secrets/db-password
[INFO]    1234-sample-app
[WARN]      redis-url (1 ver) → /dev/1234-sample-app/static-secrets/redis-url

[INFO]  === Done: 3 moved, 0 failed ===
[WARN]  Dry run — re-run without --dry-run to execute.
```

### Migrate one environment at a time

```bash
./migrate-staging-secrets.sh --source /staging --envs dev
./migrate-staging-secrets.sh --source /staging --envs qa
./migrate-staging-secrets.sh --source /staging --envs preprod
./migrate-staging-secrets.sh --source /staging --envs prod
```

### Migrate all environments at once

```bash
./migrate-staging-secrets.sh --source /staging --envs dev,qa,preprod,prod
```

### Migrate a single application in prod

```bash
./migrate-staging-secrets.sh \
    --source /staging \
    --envs prod \
    --app 1015-bom-portal
```

### Use a target prefix

If your destination paths are not at the root:

```bash
./migrate-staging-secrets.sh \
    --source /my-org/staging \
    --envs dev,qa,prod \
    --target-prefix /my-org
```

This produces:

```
/my-org/staging/dev/app/secret → /my-org/dev/app/static-secrets/secret
```

### Custom environment names

The environment list is fully user-defined — use whatever names match your folder structure:

```bash
./migrate-staging-secrets.sh \
    --source /migration/holding \
    --envs uat,staging,production
```

## Recommended Workflow

1. **Dry run** to review all planned moves:

   ```bash
   ./migrate-staging-secrets.sh --source /staging --envs dev,qa,preprod,prod --dry-run
   ```

2. **Start with a non-critical environment** (e.g. dev):

   ```bash
   ./migrate-staging-secrets.sh --source /staging --envs dev
   ```

3. **Verify** a few secrets and their versions at the destination:

   ```bash
   akeyless get-secret-value --name /dev/1015-bom-portal/static-secrets/db-password
   akeyless get-secret-value --name /dev/1015-bom-portal/static-secrets/db-password --version 1
   ```

4. **Proceed** with remaining environments:

   ```bash
   ./migrate-staging-secrets.sh --source /staging --envs qa,preprod,prod
   ```

## Migration Strategy Details

The script chooses the migration strategy per application folder:

| Condition | Strategy | Speed | Versions |
|-----------|----------|-------|----------|
| Target folder does not exist | `move-objects` | Fast (1 API call per app) | All preserved natively |
| Target folder already exists | Per-item version copy | Slower (3+ API calls per secret) | All preserved via read+create+update |

The target existence check prevents a known `move-objects` behavior where it nests the source folder name inside an existing target folder, producing incorrect paths like `/<env>/<app>/static-secrets/<app>/<secret>` instead of `/<env>/<app>/static-secrets/<secret>`.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Secret value cannot be read | Logged as `FAIL read`, skipped, source untouched |
| Secret cannot be created at destination | Logged as `FAIL create`, skipped, source untouched |
| Individual version unreadable | Warning logged, other versions still migrated |
| Source cannot be deleted after successful create | Warning logged, destination secret exists (manual cleanup needed) |
| Environment folder is empty or missing | Warning logged, skipped to next environment |
| `move-objects` fails | Logged as error, counted as failure |
| Script interrupted mid-run | Safe to re-run — fallback handles existing targets automatically |

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All secrets migrated successfully (or dry run completed) |
| `1` | One or more secrets failed to migrate |
