# Clean-clone verification and all-history secret scan (2026-11-23)

**These results apply to commit `053648a7cd9b8395c3fa0083007c3a7bc3ca6bc6` only** (`main` after PR #41). They were produced locally on a developer machine, not in GitHub Actions, and nothing here touches AWS.

**Not included:** the workflow `approval-demo.yml` from PR #42 was **not** part of this clean-clone test (PR #42 is open and not merged; it is not in `053648a`). Its static content was scanned by gitleaks only as a staged diff at commit time, not in this evidence.

## 1. Clean-clone test
A new clone of `https://github.com/Bhabotos/shopnest-devops-cicd.git` was made in a temporary directory outside every existing worktree, and `053648a` was checked out (detached). The README's "Testing and validation" commands were then run with Node.js v24.15.0 and npm 11.12.1. The clone's working tree stayed unmodified (`git status` clean after every command). No source file was edited.

| Command (directory) | Exit | Result |
|---|---|---|
| `npm ci` (`frontend`) | 0 | installed, 0 vulnerabilities |
| `npm run lint` (`frontend`) | 0 | ESLint clean |
| `npm test` (`frontend`) | 0 | 5 test files, **39 passed** |
| `npm run build` (`frontend`) | 0 | Vite production build succeeded |
| `npm ci` (`backend`) | 0 | installed, 0 vulnerabilities |
| `npm run lint` (`backend`) | 0 | ESLint clean |
| `npm test` (`backend`) | 0 | **160 passed, 11 skipped** (171); 12 test files passed, 1 skipped |
| `bash deploy/tests/workflows.test.sh` | 0 | **77 passed**, 0 failed (static, reads the workflow files only) |
| `bash deploy/tests/terraform-iam.test.sh` | 0 | **97 passed**, 0 failed (static, reads the `.tf` files only) |

The 11 skipped backend tests are the PostgreSQL integration tests: they need `TEST_DATABASE_URL`, which was not set, exactly as the README documents for the plain `npm test` command. CI runs them against a PostgreSQL service. They were **not** run in this clean-clone test.

Not run in this test: the offline blue/green, metadata-guard and CI-helper suites, the Docker-based verification scripts, the local rehearsal, and `terraform fmt`/`validate` (Terraform CI covers the last one). Nothing was deployed and no AWS call was made.

## 2. Gitleaks, all history (redacted output retained)
Tool gitleaks 8.30.1, config `.gitleaks.toml` (default rules plus this repository's IP-address and EC2-hostname rules), command `gitleaks git . --config .gitleaks.toml --no-banner --redact --log-opts=--all`.

| Scan | Scope | Result | Exit | Retained output |
|---|---|---|---|---|
| Fresh clone | 47 refs fetched from GitHub; 118 commits reachable; 81 commits scanned (about 2.02 MB) | no leaks found | 0 | [`gitleaks-fresh-clone.txt`](gitleaks-fresh-clone.txt) |
| Local repository | 97 local and remote-tracking refs, including local-only branches; 128 commits reachable; 85 commits scanned (about 3.17 MB) | no leaks found | 0 | [`gitleaks-local-repo.txt`](gitleaks-local-repo.txt) |

Both scans ran before this evidence was committed. The retained files are the redacted tool output with a header; no secret value is in them.

**Limits.** "No leaks found" means no match against the configured rules. It is not proof that the repository holds no secret. Git-ignored files (for example `assignment/`, `node_modules`, `dist` and any untracked variable file) are outside this scan, as are secrets that no rule matches. The scanned-commit counts are lower than the reachable-commit counts; the cause (for example merge commits having no diff of their own) was not investigated here.

Separately, the owner-side credential rotation recorded in `PROJECT_STATUS.md` is still pending.
