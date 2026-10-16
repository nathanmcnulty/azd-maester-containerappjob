FROM --platform=linux/amd64 debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS pinned-apt

# Public package transport is authenticated by Debian signatures and the exact metadata hashes.
# The base has no CA bundle yet. Do not bypass TLS verification to bootstrap it.
COPY viewer/debian-snapshot.sources /etc/apt/sources.list.d/debian.sources
RUN test ! -e /etc/apt/sources.list \
    && test "$(find /etc/apt/sources.list.d -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 \
    && apt-get -o APT::Update::Error-Mode=any update
COPY viewer/debian-inrelease.sha256 /tmp/debian-inrelease.sha256
RUN cd /var/lib/apt/lists \
    && sha256sum --check /tmp/debian-inrelease.sha256 \
    && rm /tmp/debian-inrelease.sha256

FROM pinned-apt AS artifacts

ARG POWERSHELL_VERSION=7.6.6
ARG POWERSHELL_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
ARG CADDY_VERSION=2.11.7
ARG CADDY_SHA256=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b
ARG MAESTER_VERSION=2.2.0
ARG MAESTER_SHA256=8c8a9757771177bd89785262e6b38385cf5e5c19bb799e4399e77f6439ad699c
ARG MAESTER_TEMPLATE_SHA256=a7b8dae3d5932c3096fa98709aaab9e9c1ebbfb83b5519e524b734ec751e3416

RUN apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && test "$(dpkg --print-architecture)" = amd64
RUN mkdir -p /out/powershell /out/caddy \
    && curl --fail --location --output /tmp/powershell.tar.gz "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-x64.tar.gz" \
    && echo "${POWERSHELL_SHA256}  /tmp/powershell.tar.gz" | sha256sum --check \
    && tar -xzf /tmp/powershell.tar.gz -C /out/powershell \
    && curl --fail --location --output /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && echo "${CADDY_SHA256}  /tmp/caddy.tar.gz" | sha256sum --check \
    && tar -xzf /tmp/caddy.tar.gz -C /out/caddy caddy \
    && curl --fail --location --output /tmp/maester.nupkg "https://www.powershellgallery.com/api/v2/package/Maester/${MAESTER_VERSION}" \
    && echo "${MAESTER_SHA256}  /tmp/maester.nupkg" | sha256sum --check \
    && mkdir -p /out/viewer-assets \
    && unzip -q /tmp/maester.nupkg assets/ReportTemplate.html -d /tmp/maester \
    && echo "${MAESTER_TEMPLATE_SHA256}  /tmp/maester/assets/ReportTemplate.html" | sha256sum --check \
    && cp /tmp/maester/assets/ReportTemplate.html /out/viewer-assets/ReportTemplate.html \
    && chmod 0555 /out/powershell/pwsh /out/caddy/caddy \
    && rm -rf /tmp/powershell.tar.gz /tmp/caddy.tar.gz /tmp/maester.nupkg /tmp/maester

FROM pinned-apt AS worker
RUN apt-get install -y --no-install-recommends ca-certificates libcurl4 libgssapi-krb5-2 libicu72 libssl3 libunwind8 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 65532 viewer \
    && useradd --uid 65532 --gid 65532 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin viewer
COPY --from=artifacts /out/powershell/ /opt/microsoft/powershell/7/
COPY scripts/Maester.ViewerContent.psm1 scripts/Maester.ViewerProjection.psm1 scripts/Maester.ViewerWorker.psm1 scripts/Maester.ViewerIdentity.psm1 scripts/Start-MaesterViewer.ps1 /opt/maester-viewer/scripts/
COPY --from=artifacts /out/viewer-assets/ReportTemplate.html /opt/maester-viewer/assets/ReportTemplate.html
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
