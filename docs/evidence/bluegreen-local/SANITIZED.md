# Sanitization record

Six files in this folder were edited before publication to remove the developer's local file-system paths
(the Windows user name inside `C:/Users/<name>/…` and the local project path). No result, count,
timestamp, status line or log message was changed. The unedited originals are kept **outside** the
repository, on the author's machine, together with a SHA-256 manifest; they are not published.

Replacements (exact text, applied to the whole file):

| Original text | Replaced by |
|---|---|
| `C:/Users/User/AppData/Local/Temp` | `<LOCAL_TEMP>` |
| `/d/DevOps-Projects/shopnest-devops-cicd` | `<REPO>` |

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

Every other file in this folder (including the four request-loop logs) is byte-for-byte the original.
Their hashes: the request-loop logs of attempt 3 begin `56412da1…` (deploy B), `15958791…` (broken C) and
`ab213b12…` (rollback to A); attempt 2's failed loop begins `e4f6582a…`.

One further correction, to a file generated after attempt 4:
`attempt4-post-switch-rollback/docker-before-after.txt` first reported `listeners-on-18081=211`, because the
measuring command counted closed client connections (TIME_WAIT) as listeners. The file now says `0` and
carries a note explaining the correction; the check found 0 LISTENING sockets.
