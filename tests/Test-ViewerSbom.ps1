#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$SmokeDirectory,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [Parameter(Mandatory)][string]$SyftPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ViewerSbom.psm1') -Force
$root=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath $OutputDirectory){throw 'Output directory must be new.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$smoke=Get-Content (Join-Path $SmokeDirectory 'result.json') -Raw|ConvertFrom-Json -AsHashtable
$receipts=@()
foreach($name in 'worker','caddy'){
  $inventory=@($smoke|Where-Object name -CEQ "${name}DebianInventory")
  if($inventory.Count-ne 1){throw 'Missing smoke inventory binding.'}
  $inventory=$inventory[0].value
  $inventoryPath=Join-Path $SmokeDirectory "$name-debian-packages.tsv"
  if((Get-FileHash $inventoryPath -Algorithm SHA256).Hash-cne$inventory.sha256){throw 'Smoke inventory hash mismatch.'}
  $imageId=[string]$inventory.imageId
  if($imageId-cnotmatch'^sha256:[0-9a-f]{64}$'){throw 'Invalid smoke image ID.'}
  $archive=Join-Path $OutputDirectory "$name.docker.tar"
  & docker image save --output $archive $imageId
  if($LASTEXITCODE){throw 'Could not export the exact tested image.'}
  $syftFile=Join-Path $OutputDirectory "$name.syft.json"
  $spdxFile=Join-Path $OutputDirectory "$name.spdx.json"
  # A private network namespace and an explicit local archive prevent registry fallback.
  & sudo unshare --net -- $SyftPath scan "docker-archive:$archive" --config (Join-Path $root 'viewer/syft.yaml') -o "syft-json=$syftFile" -o "spdx-json=$spdxFile"
  if($LASTEXITCODE){throw 'Offline image SBOM generation failed.'}
  $files=@{}
  if($name-eq'worker'){
    foreach($file in 'Maester.ViewerContent.psm1','Maester.ViewerProjection.psm1','Maester.ViewerWorker.psm1','Maester.ViewerIdentity.psm1','Start-MaesterViewer.ps1'){
      $files["/opt/maester-viewer/scripts/$file"]=(Get-FileHash (Join-Path $root "scripts/$file") -Algorithm SHA256).Hash
    }
    $files['/opt/maester-viewer/assets/ReportTemplate.html']='a7b8dae3d5932c3096fa98709aaab9e9c1ebbfb83b5519e524b734ec751e3416'
    $runtime='System.Management.Automation';$version='7.6.6'
    $locations=@('/opt/microsoft/powershell/7/pwsh.deps.json','/opt/microsoft/powershell/7/System.Management.Automation.dll')
  }else{
    $files['/etc/caddy/Caddyfile']=(Get-FileHash (Join-Path $root 'viewer/Caddyfile') -Algorithm SHA256).Hash
    $runtime='github.com/caddyserver/caddy/v2';$version='v2.11.7'
    $locations=@('/usr/local/bin/caddy')
  }
  $metadataPath=Join-Path $BuildDirectory "$name.json"
  $receipt=Assert-ViewerSbom -ImageId $imageId -BuildMetadata (Get-Content $metadataPath -Raw|ConvertFrom-Json -AsHashtable) -Syft (Get-Content $syftFile -Raw|ConvertFrom-Json -AsHashtable) -Spdx (Get-Content $spdxFile -Raw|ConvertFrom-Json -AsHashtable) -DebianInventory (Get-Content $inventoryPath) -RequiredFiles $files -RuntimePackage $runtime -RuntimeVersion $version -RuntimeLocations $locations
  $receipts+=@{image=$name;validation=$receipt;files=@($metadataPath,$inventoryPath,$syftFile,$spdxFile|ForEach-Object {@{name=[IO.Path]::GetFileName($_);sha256=(Get-FileHash $_ -Algorithm SHA256).Hash}})}
  # Only successful, verified scans discard the large local transport archive.
  Remove-Item -LiteralPath $archive
}
$source=& git -C $root rev-parse HEAD
if($LASTEXITCODE-or$source-cnotmatch'^[0-9a-f]{40}$'){throw 'Cannot identify checked-out source.'}
@{sourceCommit=$source;githubRunId=$env:GITHUB_RUN_ID;syft='1.54.1';configSha256=(Get-FileHash (Join-Path $root 'viewer/syft.yaml') -Algorithm SHA256).Hash;images=$receipts}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $OutputDirectory 'result.json') -Encoding utf8
