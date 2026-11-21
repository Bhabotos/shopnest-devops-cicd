# SHA comparison: proposed canonical workflow vs ci.yml

Label: analysis added by the assistant (Claude), **not Copilot output**. No workflow content and no SHA was
changed. Action SHAs were verified against GitHub on 2026-11-21 (read-only).

The proposed canonical workflow is the second (secure) workflow, `.github/workflows/pipeline-demo.yml`.

| Action | `pipeline-demo.yml` (canonical) | `ci.yml` | Difference |
|---|---|---|---|
| actions/checkout | `11d5960a326750d5838078e36cf38b85af677262` (tag v4.4.0) | `3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1) | different; older major version |
| actions/setup-node | `49933ea5288caeca8642d1e84afbd3f7d6820020` (tag v4.4.0) | `949feb2413d6458794dcd2491c4babbbce0c15c1` (v7.1.0) | different; older major version |

- Both canonical SHAs are real commits with valid GitHub signatures.
- v7.0.1 and v7.1.0 were the latest releases of the two actions when checked.
- The canonical workflow also has no version comments, no `persist-credentials: false` on checkout and no
  `timeout-minutes`, which `ci.yml` uses.
- Decision pending (owner): keep the canonical file unedited as the Copilot output, and record any alignment
  with `ci.yml` as separate, documented edits.
