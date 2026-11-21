#!/usr/bin/env bash
# A fake `docker` for deploy/tests/bluegreen-logic.test.sh. It keeps its "containers" and "images"
# as files under $FAKE, so the real deploy scripts can be exercised without a Docker engine.
# Failure switches (create the file to turn the failure on):
#   $FAKE/bad_health/<sha>      the release with this SHA reports an unhealthy /health everywhere
#   $FAKE/postswitch_bad/<sha>  validation on the colour passes, but traffic through nginx fails
#   $FAKE/start_fail/<sha>      the container for this SHA cannot start
#   $FAKE/migrate_fail          the migrate job exits non-zero
#   $FAKE/nginx_t_fail          `nginx -t` fails
#   $FAKE/pull_fail             `docker pull` fails (the image is not in the registry any more)
#   $FAKE/pull_wrong_revision   the pulled image carries a different revision label than the release SHA
set -u
: "${FAKE:?FAKE must point at the fake engine state directory}"
mkdir -p "$FAKE/running" "$FAKE/images"
log() { echo "$*" >> "$FAKE/calls.log"; }

# Record which colour and release nginx would serve, as of its current active.conf.
served_from_conf() {
  local conf="$ENV_DIR/nginx/upstream/active.conf" colour sha
  [ -f "$conf" ] || return 0
  colour="$(sed -n 's/.*server backend-\([a-z]*\):3000;.*/\1/p' "$conf")"
  sha="$(sed -n 's#.*default /srv/frontend/releases/\([0-9a-f]*\);.*#\1#p' "$conf")"
  printf '%s %s\n' "$colour" "$sha" > "$FAKE/served"
}
tag_of() { case "$1" in backend-blue) echo "${BLUE_TAG:-none}" ;; backend-green) echo "${GREEN_TAG:-none}" ;; esac; }

case "${1:-}" in
  load)
    log "load"
    if [ -f "$FAKE/load-tag" ]; then cp "$FAKE/load-tag" "$FAKE/images/$(cat "$FAKE/load-tag")"; fi
    exit 0 ;;
  image) # docker image inspect shopnest-backend:<tag> --format ...
    tag="${3#shopnest-backend:}"
    [ -f "$FAKE/images/$tag" ] || exit 1
    cat "$FAKE/images/$tag"
    exit 0 ;;
  pull) # docker pull <ref>: remember which revision the pulled image carries
    log "pull $2"
    [ -f "$FAKE/pull_fail" ] && exit 1
    if [ -f "$FAKE/pull_wrong_revision" ]; then echo wrong > "$FAKE/last_pull_revision"; else cp "$FAKE/load-tag" "$FAKE/last_pull_revision"; fi
    exit 0 ;;
  tag) # docker tag <ref> shopnest-backend:<tag>
    log "tag $2 $3"
    cp "$FAKE/last_pull_revision" "$FAKE/images/${3#shopnest-backend:}"
    exit 0 ;;
  login)
    cat > /dev/null
    log "login"
    exit 0 ;;
  compose) shift ;;
  *) exit 0 ;;
esac

compose_files=""
while [ "${1:-}" = "-p" ] || [ "${1:-}" = "-f" ]; do
  if [ "$1" = "-f" ]; then compose_files="$compose_files $(basename "$2")"; fi
  shift 2
done
log "composefiles$compose_files"
sub="${1:-}"
shift || true

case "$sub" in
  up)
    log "upcall $*"
    for svc in "$@"; do
      case "$svc" in
        -*) continue ;;
        db) touch "$FAKE/running/db"; log "up db" ;;
        nginx) served_from_conf; touch "$FAKE/running/nginx"; log "up nginx" ;;
        backend-blue | backend-green)
          tag="$(tag_of "$svc")"
          log "up $svc $tag"
          if [ -f "$FAKE/start_fail/$tag" ]; then exit 1; fi
          echo "$tag" > "$FAKE/running/$svc" ;;
      esac
    done
    exit 0 ;;
  ps)
    if [[ " $* " == *" nginx "* ]] && [ -f "$FAKE/running/nginx" ]; then echo "container-nginx"; fi
    exit 0 ;;
  stop | rm)
    for svc in "$@"; do
      case "$svc" in -*) continue ;; esac
      rm -f "$FAKE/running/$svc"
      log "$sub $svc"
    done
    exit 0 ;;
  logs) echo "(fake container logs)"; exit 0 ;;
  run)
    svc="${*: -1}"
    log "run $svc"
    if [ "$svc" = migrate ] && [ -f "$FAKE/migrate_fail" ]; then exit 1; fi
    exit 0 ;;
  exec)
    shift # -T
    svc="$1"
    shift
    case "$svc" in
      db) [ -f "$FAKE/running/db" ]; exit $? ;;
      backend-blue | backend-green)
        [ -f "$FAKE/running/$svc" ] || exit 1
        tag="$(cat "$FAKE/running/$svc")"
        js="$*"
        case "$js" in
          *"/health"*) [ -f "$FAKE/bad_health/$tag" ] && exit 1; exit 0 ;;
          *"/version"*) echo "$tag"; exit 0 ;;
        esac
        exit 0 ;;
      nginx)
        case "$1" in
          nginx)
            if [ "$2" = "-t" ]; then log "nginx-t"; [ -f "$FAKE/nginx_t_fail" ] && exit 1; exit 0; fi
            if [ "$2" = "-s" ]; then served_from_conf; log "reload"; exit 0; fi ;;
          wget)
            url="${*: -1}"
            [ -f "$FAKE/served" ] || exit 1
            read -r colour served_sha < "$FAKE/served"
            [ -f "$FAKE/running/backend-$colour" ] || exit 1
            tag="$(cat "$FAKE/running/backend-$colour")"
            [ -f "$FAKE/bad_health/$tag" ] && exit 1
            [ -f "$FAKE/postswitch_bad/$served_sha" ] && exit 1
            case "$url" in
              */health) echo '{"status":"ok"}' ;;
              */version) printf '{"version":"x","commit":"%s"}\n' "$tag" ;;
              *) exit 1 ;;
            esac
            exit 0 ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
