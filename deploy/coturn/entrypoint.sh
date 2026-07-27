#!/bin/sh
set -eu

: "${TURN_REALM:=glasstunnel.local}"
: "${TURN_SERVER_NAME:=glasstunnel.local}"
: "${TURN_USER:=glasstunnel}"
: "${TURN_PASSWORD:?TURN_PASSWORD must be set}"

template=/etc/coturn/turnserver.conf.template
rendered=/tmp/turnserver.conf

sed \
  -e "s|__TURN_REALM__|${TURN_REALM}|g" \
  -e "s|__TURN_SERVER_NAME__|${TURN_SERVER_NAME}|g" \
  -e "s|__TURN_USER__|${TURN_USER}|g" \
  -e "s|__TURN_PASSWORD__|${TURN_PASSWORD}|g" \
  "$template" >"$rendered"

exec turnserver -c "$rendered"
