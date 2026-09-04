#!/usr/bin/env bash
# Download the Spleeter pretrained models ONCE into a local cache, so no pod
# ever fetches them from GitHub again. ~417MB for all three; 2stems (76MB) is
# the only one the app actually uses.
#
#   bash local-deploy/fetch-models.sh            # 2stems only (default)
#   MODELS="2stems 4stems 5stems" bash local-deploy/fetch-models.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODELS="${MODELS:-2stems}"
BASE_URL="https://github.com/deezer/spleeter/releases/download/v1.4.0"
DEST="$CACHE_DIR/models"
mkdir -p "$DEST"

step "fetching spleeter models -> $DEST"
for m in $MODELS; do
  if [ -f "$DEST/$m/model.index" ]; then
    c_ok "$m already cached ($(du -sh "$DEST/$m" | cut -f1))"
    continue
  fi
  c_info "downloading $m ..."
  mkdir -p "$DEST/$m"
  if ! curl -fsSL "$BASE_URL/$m.tar.gz" | tar xz -C "$DEST/$m"; then
    rm -rf "$DEST/$m"
    die "failed to download $m -- check network access to github.com"
  fi
  [ -f "$DEST/$m/model.index" ] || { rm -rf "$DEST/$m"; die "$m archive looked wrong"; }
  c_ok "$m ($(du -sh "$DEST/$m" | cut -f1))"
done
c_info "total cached: $(du -sh "$DEST" | cut -f1)"
