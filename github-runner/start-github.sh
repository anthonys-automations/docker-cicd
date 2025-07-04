#!/bin/bash

ORGANIZATION=$ORGANIZATION
ACCESS_TOKEN=$ACCESS_TOKEN
LABELS=$LABELS

# Path to the Docker socket
DOCKER_SOCK="/var/run/docker.sock"

# Check if the Docker socket exists
if [ -S "${DOCKER_SOCK}" ]; then
    # Retrieve the GID of the Docker socket
    DOCKER_GID=$(stat -c '%g' "${DOCKER_SOCK}")
    
    if [ -n "${DOCKER_GID}" ]; then
        groupmod -g "${DOCKER_GID}" docker
        usermod -aG docker ${USER}
    fi
fi

REG_TOKEN=$(curl -sX POST -H "Authorization: token ${ACCESS_TOKEN}" https://api.github.com/orgs/${ORGANIZATION}/actions/runners/registration-token | jq .token --raw-output)

cd /opt/actions-runner
sudo -u ${USER} /opt/actions-runner/config.sh --url https://github.com/${ORGANIZATION} --token ${REG_TOKEN}

cleanup() {
    echo "Refreshing registration token..."
    REG_TOKEN=$(curl -sX POST -H "Authorization: token ${ACCESS_TOKEN}" https://api.github.com/orgs/${ORGANIZATION}/actions/runners/registration-token | jq .token --raw-output)
    echo "Removing runner..."
    sudo -u ${USER} /opt/actions-runner/config.sh remove --unattended --token ${REG_TOKEN} --labels "${LABELS}"
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

sudo -u ${USER} /opt/actions-runner/run.sh & wait $!
