#!/usr/bin/env bash
# Runs the CodeBuild MIGRATOR for one release and waits for it. A build that does not SUCCEED fails this script, and the
# workflow stops there: a failed migration blocks the deployment. The schema is never reversed automatically.
#
#   run-codebuild.sh --project <name> --image-ref <registry/repo@sha256:digest> --release-sha <40 hex> --region <region>
#                    [--poll <seconds>] [--max-wait <seconds>]
#
# The build runs INSIDE the release image (the image override, by digest), so it applies exactly the migrations that ship with
# the release. Exit codes: 0 succeeded; 1 the build failed, timed out or was stopped; 2 bad arguments.
set -euo pipefail

die() { echo "run-codebuild: ERROR: $*" >&2; exit 2; }

PROJECT="" IMAGE_REF="" SHA="" REGION="" POLL=10 MAX_WAIT=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --image-ref) IMAGE_REF="${2:-}"; shift 2 ;;
    --release-sha) SHA="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --poll) POLL="${2:-}"; shift 2 ;;
    --max-wait) MAX_WAIT="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,254}$ ]] || die "--project is not a CodeBuild project name"
[[ "$IMAGE_REF" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]] || die "--image-ref must be an ECR image DIGEST (never a tag)"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "--release-sha must be a full 40-character commit SHA"
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "--region is not a region"
[[ "$POLL" =~ ^[0-9]+$ && "$MAX_WAIT" =~ ^[0-9]+$ ]] || die "--poll and --max-wait must be whole seconds"

BUILD_ID="$(aws codebuild start-build --region "$REGION" --project-name "$PROJECT" \
  --image-override "$IMAGE_REF" --image-pull-credentials-type-override SERVICE_ROLE \
  --environment-variables-override "name=RELEASE_SHA,value=$SHA,type=PLAINTEXT" \
  --query 'build.id' --output text)" || { echo "run-codebuild: could not start the build" >&2; exit 1; }
echo "migrator build started: $BUILD_ID"

waited=0
status="IN_PROGRESS"
while [ "$waited" -le "$MAX_WAIT" ]; do
  status="$(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)" || status="UNKNOWN"
  case "$status" in
    SUCCEEDED) echo "migrator build succeeded"; exit 0 ;;
    FAILED | FAULT | STOPPED | TIMED_OUT) break ;;
  esac
  sleep "$POLL"
  # Time always advances (at least one second per round), so a build that never finishes ends in a failure, never a hang.
  waited=$((waited + (POLL > 0 ? POLL : 1)))
done

if [ "$status" = "IN_PROGRESS" ] || [ "$status" = "UNKNOWN" ]; then status="NOT_FINISHED"; fi
echo "::error::the migrator build did not succeed (status: $status). The deployment is blocked; nothing was deployed."
# The tail of the build log, for the operator. The job prints no secret, so neither does this.
group="$(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" --query 'builds[0].logs.groupName' --output text 2> /dev/null || true)"
stream="$(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" --query 'builds[0].logs.streamName' --output text 2> /dev/null || true)"
if [ -n "$group" ] && [ "$group" != "None" ] && [ -n "$stream" ] && [ "$stream" != "None" ]; then
  echo "---- last lines of the build log ----"
  aws logs get-log-events --region "$REGION" --log-group-name "$group" --log-stream-name "$stream" --limit 60 --query 'events[].message' --output text 2> /dev/null || echo "(the log could not be read)"
fi
exit 1
