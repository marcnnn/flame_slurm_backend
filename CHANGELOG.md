# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Unreleased

<!-- Add your changelog entry to the relevant subsection -->

<!-- ### Added | Changed | Deprecated | Removed | Fixed | Security -->

### Added

- `:job_poll_interval` option (default 5s): while waiting for a runner, the job state is polled with `squeue` and boot fails early if the job ends before connecting.
- `FLAME_SLURM_BACKEND_PATH`: runners install the backend from a path, e.g. a checkout on the cluster's shared `$HOME`.
- `:boot_backoff_base` / `:boot_backoff_max` (default 1s / 60s): failed boots back off exponentially per job script.

### Fixed

- Failed boots no longer flood Slurm: FLAME.Pool retries about every second while callers wait, which submitted ~300 jobs in 5 minutes during testing on allegro.
- Jobs that failed before connecting were not detected, because `squeue` hides finished jobs by default. Now uses `squeue -t all` with an `sacct` fallback.
- `--signal=B:SIGTERM@30` is now passed to `sbatch` on the command line; as an `#SBATCH` directive after the user's script commands it was silently ignored.
- The runner is started with `exec`, so the SIGTERM actually reaches the BEAM instead of only the batch shell.
- Each submission uses its own temporary job script (removed after submission) instead of a shared `flame_auto.sh` in the working directory, fixing races when several runners boot at once.
- `sbatch` failures return `{:error, reason}` from `remote_boot/1` instead of crashing with a `CaseClauseError`; job ids are parsed via `--parsable`, tolerating warnings and multi-cluster output.
- A failing `scancel` on boot timeout is logged instead of crashing.
- Negative remaining boot windows no longer crash `receive`.
- The encoded `FLAME_PARENT` is no longer printed to the job log.
- `path_job_id/1` also accepts `SLURM_JOB_ID`.
- Missing `sbatch`, `squeue` or `scancel` executables return errors instead of raising.
- An unwritable temp dir returns an error instead of raising.
- Job scripts without a `#!` line get `#!/bin/bash` prepended (sbatch rejects them otherwise).
- An empty `SLURM_FLAME_HOST` (e.g. no `ib0` interface) falls back to the FQDN instead of producing an invalid node name.
- When the backend application can't be resolved, the runner installs `flame_slurm_backend` at the parent's version instead of failing on a `{nil, nil}` dependency.
- `boot_timeout: :infinity` is supported.
- `log: true` logs at `:info` instead of crashing `Logger.log/3`.
- `:slurm_job`, `:boot_timeout` and `:job_poll_interval` are validated in `init/1`.
- README example now passes `slurm_job` to the backend instead of to `FLAME.Pool`.

<!--------------------- Don't add new entries after this line --------------------->


## [0.1.0] - 2024-11-02

- Very early stage implementation of a Slurm backend.
