# base
FROM ubuntu:22.04

# set the github runner version
ARG RUNNER_VERSION="2.321.0"
ARG ARCHITECTURE="arm64"

ARG DEBIAN_FRONTEND=noninteractive

# update the base packages and add a non-sudo user
RUN apt-get update -y && apt-get upgrade -y && useradd -d /opt/actions-runner --system github

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl jq build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
    docker.io docker-compose-v2 ; apt-get clean

RUN cd /opt && mkdir actions-runner && cd actions-runner \
    && curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCHITECTURE}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-${ARCHITECTURE}-${RUNNER_VERSION}.tar.gz

RUN /opt/actions-runner/bin/installdependencies.sh ; apt-get clean

RUN curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash ; apt-get clean

# copy over the start.sh script
COPY start.sh start.sh
#COPY docker-build.sh /opt/actions-runner/docker-build.sh
#COPY docker-build.sudo /etc/sudoers.d/docker-build

# make the script executable
RUN chmod +x start.sh && chmod g+w /opt/actions-runner && chown -R root:github /opt/actions-runner

# since the config and run script for actions are not allowed to be run by root,
# set the user to "github" so all subsequent commands are run as the github user
USER github

# set the entrypoint to the start.sh script
ENTRYPOINT ["./start.sh"]
