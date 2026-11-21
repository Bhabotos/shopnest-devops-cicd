# 02a: first workflow response

Label: EXACT COPY of `docs/copilot/02-copilot-response.md` (SHA-256 prefix 61db66d95a784dd0, 2951 bytes).
The original file is preserved unchanged next to this one.

Caveats:
- The saved text is a rendered-markdown copy, not Copilot's plain code block: it contains `&#x20;` entities,
  backslash escapes and double spacing, so it is **not valid YAML as saved**.
- Mapping to Prompt 1 (`01-prompt.md`) is the owner's statement and is **PARTIAL**: not independently verified.
- Any explanation text Copilot gave with this response is **UNAVAILABLE**.

## Verbatim content

````text
name: Pipeline Demo



on:

&#x20; push:

&#x20;   branches:

&#x20;     - 'demo/\*\*'

&#x20; workflow\_dispatch:

&#x20;   inputs:

&#x20;     health\_check\_url:

&#x20;       description: HTTPS endpoint to check; do not enter credentials or sensitive addresses

&#x20;       required: false

&#x20;       type: string

&#x20;       default: https://api.github.com/zen



permissions: {}



jobs:

&#x20; backend-tests:

&#x20;   name: Backend tests (Node.js 24)

&#x20;   runs-on: ubuntu-latest

&#x20;   timeout-minutes: 15

&#x20;   permissions:

&#x20;     contents: read

&#x20;   defaults:

&#x20;     run:

&#x20;       working-directory: backend

&#x20;   steps:

&#x20;     - name: Check out repository

&#x20;       uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

&#x20;       with:

&#x20;         persist-credentials: false



&#x20;     - name: Set up Node.js 24

&#x20;       uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0

&#x20;       with:

&#x20;         node-version: 24

&#x20;         cache: npm

&#x20;         cache-dependency-path: backend/package-lock.json



&#x20;     - name: Install dependencies from lockfile

&#x20;       run: npm ci



&#x20;     - name: Run backend tests

&#x20;       run: npm test



&#x20; deploy-check:

&#x20;   name: Endpoint health check

&#x20;   runs-on: ubuntu-latest

&#x20;   timeout-minutes: 5

&#x20;   permissions: {}

&#x20;   steps:

&#x20;     - name: Check HTTPS endpoint

&#x20;       env:

&#x20;         HEALTH\_CHECK\_URL: ${{ inputs.health\_check\_url || 'https://api.github.com/zen' }}

&#x20;       run: |

&#x20;         set -euo pipefail



&#x20;         case "$HEALTH\_CHECK\_URL" in

&#x20;           https://\*) ;;

&#x20;           \*)

&#x20;             echo "::error::Health check URL must use HTTPS."

&#x20;             exit 1

&#x20;             ;;

&#x20;         esac



&#x20;         if ! http\_status="$(

&#x20;           curl \\

&#x20;             --silent \\

&#x20;             --show-error \\

&#x20;             --location \\

&#x20;             --fail \\

&#x20;             --output /dev/null \\

&#x20;             --write-out '%{http\_code}' \\

&#x20;             --connect-timeout 5 \\

&#x20;             --max-time 15 \\

&#x20;             "$HEALTH\_CHECK\_URL"

&#x20;         )"; then

&#x20;           echo "::error::Health check failed: DNS, connection, request timeout, or HTTP error."

&#x20;           exit 1

&#x20;         fi



&#x20;         if \[\[ "$http\_status" =\~ ^2\[0-9]{2}$ ]]; then

&#x20;           echo "Health check passed."

&#x20;         else

&#x20;           echo "::error::Health check failed: endpoint did not return a 2xx response."

&#x20;           exit 1

&#x20;         fi

````
