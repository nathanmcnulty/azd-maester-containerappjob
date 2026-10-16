FROM --platform=linux/amd64 debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS artifacts

ARG POWERSHELL_VERSION=7.6.6
ARG POWERSHELL_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
ARG CADDY_VERSION=2.11.7
ARG CADDY_SHA256=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && test "$(dpkg --print-architecture)" = amd64
RUN mkdir -p /out/powershell /out/caddy \
    && curl --fail --location --output /tmp/powershell.tar.gz "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-x64.tar.gz" \
    && echo "${POWERSHELL_SHA256}  /tmp/powershell.tar.gz" | sha256sum --check \
    && tar -xzf /tmp/powershell.tar.gz -C /out/powershell \
    && curl --fail --location --output /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && echo "${CADDY_SHA256}  /tmp/caddy.tar.gz" | sha256sum --check \
    && tar -xzf /tmp/caddy.tar.gz -C /out/caddy caddy \
    && chmod 0555 /out/powershell/pwsh /out/caddy/caddy \
    && rm -f /tmp/powershell.tar.gz /tmp/caddy.tar.gz

FROM --platform=linux/amd64 debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS worker
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libcurl4 libgssapi-krb5-2 libicu72 libssl3 libunwind8 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 65532 viewer \
    && useradd --uid 65532 --gid 65532 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin viewer
COPY --from=artifacts /out/powershell/ /opt/microsoft/powershell/7/
COPY scripts/Maester.ViewerProjection.psm1 scripts/Maester.ViewerWorker.psm1 scripts/Maester.ViewerIdentity.psm1 scripts/Start-MaesterViewer.ps1 /opt/maester-viewer/scripts/
ENV HOME=/tmp \
    DOTNET_CLI_HOME=/tmp/dotnet \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    NUGET_XMLDOC_MODE=skip
USER 65532:65532
EXPOSE 8081
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/microsoft/powershell/7/pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/maester-viewer/scripts/Start-MaesterViewer.ps1"]

FROM --platform=linux/amd64 debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS caddy
RUN groupadd --gid 65532 viewer \
    && useradd --uid 65532 --gid 65532 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin viewer
COPY --from=artifacts /out/caddy/caddy /usr/local/bin/caddy
COPY viewer/Caddyfile /etc/caddy/Caddyfile
ENV HOME=/tmp \
    XDG_CONFIG_HOME=/tmp/caddy-config \
    XDG_DATA_HOME=/tmp/caddy-data
USER 65532:65532
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
