#!/bin/sh

if [ -z "${REGISTRY_PASSWORD}" ] ; then
  echo "REGISTRY_PASSWORD not set"
  exit 255
fi

REGISTRY='registry.oci.verevkin.ca:5000'
IMAGE_NAME='infrastructure/github-runner'

# Exit on errors
set -e

cp -a /usr/local/share/ca-certificates build/

# Clean up old login session
rm /root/.docker/config.json || true

docker login -u github --password-stdin ${REGISTRY} << EOF
${REGISTRY_PASSWORD}
EOF

docker image build . --pull --no-cache --force-rm --tag ${REGISTRY}/${IMAGE_NAME}
docker image push ${REGISTRY}/${IMAGE_NAME}
docker image prune -a -f
