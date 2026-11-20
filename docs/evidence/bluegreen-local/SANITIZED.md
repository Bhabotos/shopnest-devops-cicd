# Sanitization record

Ten files in this folder were edited before publication to remove the developer's local file-system paths
(the Windows user name inside `C:/Users/<name>/…` and the local project path). No result, count,
timestamp, status line or log message was changed. The unedited originals are kept **outside** the
repository, on the author's machine, together with a SHA-256 manifest; they are not published.

Replacements (exact text, applied to the whole file):

| Original text | Replaced by |
|---|---|
| `C:/Users/<local user name>/AppData/Local/Temp` (the actual user name is not repeated here) | `<LOCAL_TEMP>` |
| `/d/DevOps-Projects/shopnest-devops-cicd` | `<REPO>` |
| `client: <address>` in nginx error-log lines: the Docker bridge gateway of the throwaway Compose network (a private container-network address, not a server) | `client: <docker-bridge-gateway>` |

Random temporary directory names such as `tmp.Vpm93si4Az` were left as they are: they are `mktemp`
output and identify nothing.

| File | Line | SHA-256 of the original | SHA-256 as published |
|---|---|---|---|
| `attempt1-failed-secrets-mode600/01-deploy-A.log` | 1 | `b2729f5b84ab26e1ea831d5010d121912f591110e0c7bd73152de4ff3f8ea966` | `df0f88ba0879db918ae27e441cd370080658b5f896dd5f092f067c1da057c77b` |
| `attempt1-failed-secrets-mode600/console.txt` | 6 | `e655be292ad778917a836798165f942311f9dda17fd4ba00fea124900e13ca30` | `abc285060f5cf02082ebbf4f079758e8ea1c5bf2968ebc227fb339bfc8f94e01` |
| `attempt3/03-deploy-C-broken.log` | 17 | `4a64a78e3c296897c2c0b068eb928b8c00c70df508ba3f6fdb3bb1723f6c6f04` | `4802694bad6e64fe685e05c911b79d92c12db0660ae8a88ed416649851d3d7c4` |
| `attempt3/console.txt` | 36 | `34f4354f3ac0333bef55088ab01c38704b93aeb7c1edaa8c8ead7ead583fa62a` | `b64157a49f87c0e5d5bb4b5b7ecde65c678c2dbe1b65a3410b252eff7d4c9131` |
| `attempt4-post-switch-rollback/05-deploy-D-post-switch-failure.log` | 26 | `dcd83de6b34490596d30f3946c96a2f6b0db136f25b2c2fbd17010f5d0054c9b` | `f86adc4ce0676f2fa0f4d807e560132295a498e0f975f3ac52febada7b1ae451` |
| `attempt4-post-switch-rollback/console.txt` | 28 | `febb128a60e995f9735579124abfd2607c0e66d3cff77f819212c6d87f996299` | `4bd09670e69cdd7badaa6ad5a2c1d841a6a7fa07629c42db12fb2c970db4012b` |
| `attempt5-all-scenarios/03-deploy-C-broken.log` | 18 | `0631dce1811598faf7d0d86620ae0218f9a7d2ef2b6f25bb934571546623f904` | `e6644e93f564ab6e10f91e61c12a7df79ae1254f7ab21311aed23b74473a6101` |
| `attempt5-all-scenarios/06-deploy-E-post-switch-failure.log` | 26 | `12c6cffd1feeb07e821cb84c3a0e0fec480fbb42138edb941d9f0353cb6c074b` | `1d468d733afcee745acb5cd1d9543d7c31b5efff043254d4a915e23d940aa9e6` |
| `attempt5-all-scenarios/console.txt` | 55 | `162b9aabb296de2b70850704848de23cca8dee504123b461bdea2ba4594cca6d` | `de8108cba8f4327cb28324cd4bb20676fbb475098a332f31c5df17ac56ebfbe6` |
| `attempt5-all-scenarios/06-nginx-errors-excerpt.txt` | 1-5 | `d9b8057f25f7105dc6f5b3d97c569304a3f0f9ee21e89d43870d2af011ef7960` | `035d2cbf3db44763429ab86ca8efca9847cf1212edea04f4a8792b0577bd6268` |

Every other file in this folder (including all request-loop logs) is byte-for-byte the original. Note: the first version of this file, already pushed in an earlier commit, printed the user name in the replacement table; it is a generic Windows account name, not a credential, and is no longer repeated here.

Their hashes: the request-loop logs of attempt 3 begin `56412da1…` (deploy B), `15958791…` (broken C) and
`ab213b12…` (rollback to A); attempt 2's failed loop begins `e4f6582a…`.

One further correction, to a file generated after attempt 4:
`attempt4-post-switch-rollback/docker-before-after.txt` first reported `listeners-on-18081=211`, because the
measuring command counted closed client connections (TIME_WAIT) as listeners. The file now says `0` and
carries a note explaining the correction; the check found 0 LISTENING sockets.
