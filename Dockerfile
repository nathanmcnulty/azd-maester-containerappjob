# Container Apps Jobs use Linux x64; install the exact stable PowerShell release.
FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-noble@sha256:9bc5729cebc4847b28da997c802ab71ce3a2ac42512260c3a151f61132b26f7b

ENV POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1

RUN test "$(uname -m)" = "x86_64" \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl --fail --show-error --silent --location \
        https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz \
        --output /tmp/powershell.tar.gz \
    && echo "DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC  /tmp/powershell.tar.gz" | sha256sum --check --strict - \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar --extract --gzip --file /tmp/powershell.tar.gz --directory /opt/microsoft/powershell/7 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && rm /tmp/powershell.tar.gz \
    && rm -rf /var/lib/apt/lists/*

SHELL ["pwsh", "-NoLogo", "-NoProfile", "-Command"]
RUN $ErrorActionPreference = 'Stop'; if ($PSVersionTable.PSVersion.ToString() -cne '7.6.6') { throw 'Unexpected PowerShell runtime.' }

# Download exact package bytes and verify SHA-256 before extraction.
COPY runtime-packages.lock.json /tmp/runtime-packages.lock.json
COPY scripts/Install-LockedModules.ps1 /tmp/Install-LockedModules.ps1
RUN $ErrorActionPreference = 'Stop'; & /tmp/Install-LockedModules.ps1 -LockPath /tmp/runtime-packages.lock.json

# ACR mode carries all executable runner content in the digest-pinned image.
COPY scripts/Invoke-MaesterContainerJob.ps1 scripts/Maester.AssessmentEvidence.psm1 scripts/Maester.DriftInputs.psm1 scripts/Maester.DriftRun.psm1 scripts/Start-MaesterContainerJob.sh /opt/maester/
COPY runtime-packages.lock.json /opt/maester/runtime-packages.lock.json
CMD ["/bin/sh", "/opt/maester/Start-MaesterContainerJob.sh", "acr"]
