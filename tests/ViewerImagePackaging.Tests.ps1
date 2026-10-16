#Requires -Version 7.6
BeforeAll {
  $root=Split-Path $PSScriptRoot -Parent
  $script:dockerfile=Get-Content (Join-Path $root 'viewer/Dockerfile') -Raw
  $script:workflow=Get-Content (Join-Path $root '.github/workflows/validate.yml') -Raw
}

Describe 'Viewer image packaging contract' {
  It 'pins the selected base and downloaded archives while limiting runtime source content' {
    $dockerfile|Should -Not -Match '(?m)^# syntax='
    @($dockerfile|Select-String -AllMatches 'debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91').Matches.Count|Should -Be 2
    $dockerfile|Should -Match '(?m)^FROM pinned-apt AS artifacts$'
    $dockerfile|Should -Match '(?m)^FROM pinned-apt AS worker$'
    $dockerfile|Should -Match 'POWERSHELL_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc'
    $dockerfile|Should -Match 'CADDY_SHA256=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b'
    $dockerfile|Should -Match 'MAESTER_SHA256=8c8a9757771177bd89785262e6b38385cf5e5c19bb799e4399e77f6439ad699c'
    $dockerfile|Should -Match 'MAESTER_TEMPLATE_SHA256=a7b8dae3d5932c3096fa98709aaab9e9c1ebbfb83b5519e524b734ec751e3416'
    @($dockerfile|Select-String -AllMatches 'sha256sum --check').Matches.Count|Should -Be 5

    $workerStage=($dockerfile-split'(?m)^FROM .* AS worker$')[1]-split'(?m)^FROM .* AS caddy$'|Select-Object -First 1
    $caddyStage=($dockerfile-split'(?m)^FROM .* AS caddy$')[1]
    @($workerStage|Select-String -AllMatches '(?m)^COPY (?!\-\-from=)[^\r\n]+').Matches.Value|Should -Be @(
      'COPY scripts/Maester.ViewerContent.psm1 scripts/Maester.ViewerProjection.psm1 scripts/Maester.ViewerWorker.psm1 scripts/Maester.ViewerIdentity.psm1 scripts/Start-MaesterViewer.ps1 /opt/maester-viewer/scripts/'
    )
    @($caddyStage|Select-String -AllMatches '(?m)^COPY (?!\-\-from=)[^\r\n]+').Matches.Value|Should -Be @('COPY viewer/Caddyfile /etc/caddy/Caddyfile')
    "$workerStage`n$caddyStage"|Should -Not -Match '(?m)^COPY \. '
    "$workerStage`n$caddyStage"|Should -Not -Match 'https?://'
  }

  It 'keeps separate nonroot one-process targets under behavioral CI smoke' {
    $dockerfile|Should -Match '(?m)^FROM .* AS worker$'
    $dockerfile|Should -Match '(?m)^FROM .* AS caddy$'
    @($dockerfile|Select-String -AllMatches '(?m)^USER 65532:65532$').Matches.Count|Should -Be 2
    $dockerfile|Should -Match ([regex]::Escape('ENTRYPOINT ["/opt/microsoft/powershell/7/pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/opt/maester-viewer/scripts/Start-MaesterViewer.ps1"]'))
    $dockerfile|Should -Match ([regex]::Escape('ENTRYPOINT ["/usr/local/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]'))
    $dockerfile|Should -Not -Match '(?m)^VOLUME '
    $dockerfile|Should -Not -Match '(?m)^CMD '
    $workflow|Should -Match 'docker buildx build [^\r\n]+--platform linux/amd64 --target worker'
    $workflow|Should -Match 'docker buildx build [^\r\n]+--platform linux/amd64 --target caddy'
    $workflow|Should -Match 'Test-ViewerImage\.ps1'
    $workflow|Should -Match 'if: always\(\)[\s\S]+actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9[\s\S]+\$\{\{ runner\.temp \}\}/viewer-image-proof'
  }
}
