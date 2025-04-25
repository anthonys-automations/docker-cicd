# base
FROM ubuntu:22.04

# set the github runner version
ARG GITHUB_RUNNER_VERSION="2.321.0"
ARG ADO_AGENT_VERSION="4.248.0"
ARG ARCHITECTURE="arm64"
ARG DEBIAN_FRONTEND=noninteractive

ENV USER=agent-runner

COPY ca-certificates/ /usr/local/share/ca-certificates/

# update the base packages and add a non-sudo user
RUN apt-get update -y && apt-get upgrade -y && useradd ${USER}

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl jq build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
    docker.io docker-compose-v2 sudo git jq libicu70 openssh-client software-properties-common \
    wget file zip unzip openjdk-21-jdk mariadb-client-10.6 apache2-utils ; \
    apt-get clean

# Install NodeJS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash - && \
    apt-get install -y nodejs && npm install --global yarn ; apt-get clean

# Install AzureCLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash ; apt-get clean

# Install Oracle OCI CLI
RUN bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults

# Install SQLCMD
RUN curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc && \
    add-apt-repository "$(wget -qO- https://packages.microsoft.com/config/ubuntu/22.04/prod.list)" && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev ; apt-get clean

# Install OWASP DependencyCheck
RUN cd /opt && VERSION=$(curl -s https://jeremylong.github.io/DependencyCheck/current.txt) \
    curl -Ls "https://github.com/jeremylong/DependencyCheck/releases/download/v$VERSION/dependency-check-$VERSION-release.zip" --output dependency-check.zip &&
    unzip dependency-check.zip && mkdir -p dependency-check/data/ && chown ${USER} dependency-check/data/

# Install docker runner
RUN cd /opt && mkdir actions-runner && cd actions-runner \
    && curl -O -L https://github.com/actions/runner/releases/download/v${GITHUB_RUNNER_VERSION}/actions-runner-linux-${ARCHITECTURE}-${GITHUB_RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-${ARCHITECTURE}-${GITHUB_RUNNER_VERSION}.tar.gz \
    && /opt/actions-runner/bin/installdependencies.sh \
    && chmod g+w /opt/actions-runner \
    && chown -R root:${USER} /opt/actions-runner ; \
    apt-get clean

# Install Azure DevOps agent
RUN cd /opt && mkdir ado-agent && cd ado-agent \
    && curl -O -L https://vstsagentpackage.azureedge.net/agent/${ADO_AGENT_VERSION}/vsts-agent-linux-${ARCHITECTURE}-${ADO_AGENT_VERSION}.tar.gz \
    && tar zxvf ./vsts-agent-linux-${ARCHITECTURE}-${ADO_AGENT_VERSION}.tar.gz \
    && /opt/ado-agent/bin/installdependencies.sh \
    && chmod g+w /opt/ado-agent \
    && chown -R root:${USER} /opt/ado-agent ; \
    apt-get clean

# copy over the start.sh script
COPY --chmod=755 start-*.sh /
COPY --chown=${USER} ssh-config /home/${USER}/.ssh/config

# set the entrypoint to the start.sh script
ENTRYPOINT ["/start-github.sh"]
