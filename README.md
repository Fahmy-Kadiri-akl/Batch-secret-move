This script automates that move for all environments and applications in a single run.

## How It Works

For each secret found under the source path, the script:

1. **Reads** the secret value from the source path
2. **Creates** a new secret at the destination path with the same value
3. **Deletes** the original secret from the source path

Secrets are processed one at a time. If a create fails, the source is not deleted — no data loss is possible.

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
Before:  /staging/prod/1015-bom-portal/db-password
After:   /prod/1015-bom-portal/static-secrets/db-password
```

## Prerequisites

- **Akeyless CLI** installed and in `PATH` ([install guide](https://docs.akeyless.io/docs/cli))
- **Authenticated session** — run `akeyless configure` or set a profile/token before using the script
- **Python 3** — used internally for recursive folder listing
- **Permissions** — the authenticated identity must have `read`, `create`, `list`, and `delete` on the relevant paths

## Installation

```bash
# Clone or copy the script
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
[WARN]      db-password → /dev/1015-bom-portal/static-secrets/db-password
[WARN]      api-key → /dev/1015-bom-portal/static-secrets/api-key
[INFO]    1234-sample-app
[WARN]      redis-url → /dev/1234-sample-app/static-secrets/redis-url

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

3. **Verify** a few secrets at the destination:

   ```bash
   akeyless get-secret-value --name /dev/1015-bom-portal/static-secrets/db-password
   ```

4. **Proceed** with remaining environments:

   ```bash
   ./migrate-staging-secrets.sh --source /staging --envs qa,preprod,prod
   ```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Secret value cannot be read | Logged as `FAIL read`, skipped, source untouched |
| Secret cannot be created at destination | Logged as `FAIL create`, skipped, source untouched |
| Source cannot be deleted after successful create | Warning logged, destination secret exists (manual cleanup needed) |
| Environment folder is empty or missing | Warning logged, skipped to next environment |
| Script interrupted mid-run | Safe to re-run — `create-secret` will fail on existing destinations, source secrets that were already moved are gone. Review and handle any partially-migrated apps manually. |

The script exits with code `1` if any secrets failed, `0` on full success.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All secrets migrated successfully (or dry run completed) |
| `1` | One or more secrets failed to migrate |
