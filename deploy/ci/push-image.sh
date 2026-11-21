#!/usr/bin/env bash
# Pushes the release's backend image to ECR and prints its DIGEST reference. Runs in the deploy job, with the short-lived
# credentials of the GitHub OIDC deploy role (no access keys).
#
#   push-image.sh --image-tar <file.tar.gz> --repository <name> --sha <40 hex> --region <region>
#
# 1. loads the image built for this exact commit and REFUSES it unless its revision label equals the commit;
# 2. pushes it under an immutable tag (the commit SHA). If that tag already exists (a re-run), nothing is pushed and the
#    existing image is used: a tag can never be overwritten, so a release tag always means the same image;
# 3. reads the digest back from ECR and prints   image_ref=<registry>/<repository>@sha256:<digest>
#    (also appended to $GITHUB_OUTPUT when that is set). Everything downstream uses the DIGEST, never the tag.
# The account id is masked in the workflow log.
set -euo pipefail

die() { echo "push-image: ERROR: $*" >&2; exit 1; }

TAR="" REPO="" SHA="" REGION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image-tar) TAR="${2:-}"; shift 2 ;;
    --repository) REPO="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$TAR" ] || die "--image-tar must be an existing file"
[[ "$REPO" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || die "--repository is not a plain repository name"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a full 40-character commit SHA"
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "--region is not a region"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || die "could not determine the AWS account"
echo "::add-mask::$ACCOUNT"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

LOCAL="shopnest-backend:$SHA"
gunzip -c "$TAR" | docker load > /dev/null || die "could not load the image tarball"
REVISION="$(docker image inspect "$LOCAL" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' 2> /dev/null || true)"
[ "$REVISION" = "$SHA" ] || die "the image's revision label '$REVISION' is not the release commit $SHA: refusing to push it"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" > /dev/null || die "could not log in to ECR"

if aws ecr describe-images --region "$REGION" --repository-name "$REPO" --image-ids "imageTag=$SHA" > /dev/null 2>&1; then
  echo "push-image: the immutable tag $SHA already exists in $REPO: using that image, pushing nothing"
else
  docker tag "$LOCAL" "$REGISTRY/$REPO:$SHA" || die "could not tag the image"
  docker push "$REGISTRY/$REPO:$SHA" > /dev/null || die "could not push the image"
  echo "push-image: pushed $REPO:$SHA"
fi

DIGEST="$(aws ecr describe-images --region "$REGION" --repository-name "$REPO" --image-ids "imageTag=$SHA" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "ECR did not return a valid digest for $REPO:$SHA"
IMAGE_REF="$REGISTRY/$REPO@$DIGEST"
echo "image_ref=$IMAGE_REF"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "image_ref=$IMAGE_REF" >> "$GITHUB_OUTPUT"; fi
