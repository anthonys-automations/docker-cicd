# base
FROM ubuntu:22.04

# set the github runner version
ARG RUNNER_VERSION="2.321.0"
ARG ARCHITECTURE="arm64"

ARG DEBIAN_FRONTEND=noninteractive

COPY ca-certificates/ /usr/local/share/ca-certificates/

# update the base packages and add a non-sudo user
RUN apt-get update -y && apt-get upgrade -y && useradd -d /opt/actions-runner --system github

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl jq build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
    docker.io docker-compose-v2 sudo git openssh-client ; apt-get clean

# Install AzureCLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash ; apt-get clean

# Install SQLCMD
RUN curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc && \
    add-apt-repository "$(wget -qO- https://packages.microsoft.com/config/ubuntu/20.04/prod.list)" && \
    apt-get update && apt-get install sqlcmd ; apt-get clean

# Install docker runner
RUN cd /opt && mkdir actions-runner && cd actions-runner \
    && curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCHITECTURE}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-${ARCHITECTURE}-${RUNNER_VERSION}.tar.gz
RUN /opt/actions-runner/bin/installdependencies.sh ; apt-get clean

# copy over the start.sh script
COPY start.sh start.sh
COPY ssh-config /opt/actions-runner/.ssh/config
#COPY docker-build.sh /opt/actions-runner/docker-build.sh
#COPY docker-build.sudo /etc/sudoers.d/docker-build

# make the script executable
RUN chmod +x start.sh && chmod g+w /opt/actions-runner && chown -R root:github /opt/actions-runner

# set the entrypoint to the start.sh script
ENTRYPOINT ["./start.sh"]
