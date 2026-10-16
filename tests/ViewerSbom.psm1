#Requires -Version 7.6
# Validation of the selected Syft image evidence, not a general SBOM validator.
function Assert-ViewerSbom {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ImageId,
    [Parameter(Mandatory)][System.Collections.IDictionary]$BuildMetadata,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Syft,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Spdx,
    [Parameter(Mandatory)][string[]]$DebianInventory,
    [Parameter(Mandatory)][System.Collections.IDictionary]$RequiredFiles,
    [Parameter(Mandatory)][string]$RuntimePackage,
    [Parameter(Mandatory)][string]$RuntimeVersion,
    [Parameter(Mandatory)][string[]]$RuntimeLocations
  )
  $ErrorActionPreference='Stop'
  if($ImageId-cnotmatch'^sha256:[0-9a-f]{64}$'){throw 'Invalid expected image ID.'}
  if($BuildMetadata['containerimage.config.digest']-cne$ImageId){throw 'Build config digest differs from tested image.'}
  if($BuildMetadata['containerimage.digest']-cnotmatch'^sha256:[0-9a-f]{64}$'-or
    $BuildMetadata['containerimage.descriptor'].digest-cne$BuildMetadata['containerimage.digest']){throw 'Missing or inconsistent build manifest digest.'}
  if(-not$BuildMetadata['buildx.build.provenance'].buildType-or-not$BuildMetadata['buildx.build.ref']){throw 'Missing BuildKit provenance or build reference.'}
  if($Syft.descriptor.name-cne'syft'-or$Syft.descriptor.version-cne'1.54.1'){throw 'Unexpected SBOM producer.'}
  if($Syft.source.type-cne'image'-or$Syft.source.metadata.imageID-cne$ImageId-or
    $Syft.source.metadata.os-cne'linux'-or$Syft.source.metadata.architecture-cne'amd64'){throw 'SBOM source differs from tested image.'}
  $config=[Convert]::FromBase64String($Syft.source.metadata.config)
  $configId='sha256:'+([Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($config)))
  if($configId-cne$ImageId){throw 'SBOM raw config does not bind its image ID.'}
  $manifest=[Convert]::FromBase64String($Syft.source.metadata.manifest)
  $manifestId='sha256:'+([Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($manifest)))
  $manifestConfig=([Text.Encoding]::UTF8.GetString($manifest)|ConvertFrom-Json -AsHashtable).config.digest
  if($manifestId-cne$Syft.source.metadata.manifestDigest-or$manifestConfig-cne$ImageId){throw 'SBOM archive manifest binding failed.'}
  if($Spdx.spdxVersion-cne'SPDX-2.3'){throw 'Expected SPDX 2.3.'}
  $describes=@($Spdx.relationships|Where-Object { $_.spdxElementId-ceq'SPDXRef-DOCUMENT'-and$_.relationshipType-ceq'DESCRIBES' })
  if($describes.Count-ne 1){throw 'Expected one SPDX document root.'}
  $roots=@($Spdx.packages|Where-Object { $_.SPDXID-ceq$describes[0].relatedSpdxElement })
  if($roots.Count-ne 1-or$roots[0].primaryPackagePurpose-cne'CONTAINER'-or$roots[0].versionInfo-cne$manifestId-or
    @($roots[0].checksums|Where-Object { $_.algorithm-ceq'SHA256'-and$_.checksumValue-ceq$manifestId.Substring(7) }).Count-ne 1){throw 'SPDX root does not bind the scanned manifest.'}

  # Require complete coverage of the independent dpkg query, not merely a package count.
  if($DebianInventory.Count-eq 0){throw 'Empty independent Debian inventory.'}
  foreach($line in $DebianInventory){
    $fields=$line-split"`t"
    if($fields.Count-ne 3){throw 'Invalid Debian inventory row.'}
    $matches=@($Syft.artifacts|Where-Object { $_.type-ceq'deb'-and$_.name-ceq$fields[0]-and$_.version-ceq$fields[1]-and$_.metadata.architecture-ceq$fields[2] })
    if($matches.Count-ne 1){throw "Missing or ambiguous Debian package: $($fields[0])."}
  }
  if(@($Syft.artifacts|Where-Object {
    $_.name-ceq$RuntimePackage-and$_.version-ceq$RuntimeVersion-and
    @($_.locations|Where-Object { $RuntimeLocations-ccontains$_.path }).Count-gt 0
  }).Count-eq 0){throw 'Missing expected copied runtime package at its runtime location.'}
  # Every cataloged package must survive conversion to SPDX with its exact purl and version.
  foreach($package in $Syft.artifacts){
    if(-not$package.purl){throw "Cataloged package has no purl: $($package.name)."}
    $converted=@($Spdx.packages|Where-Object {
      $_.versionInfo-ceq$package.version-and
      @($_.externalRefs|Where-Object { $_.referenceType-ceq'purl'-and$_.referenceLocator-ceq$package.purl }).Count-eq 1
    })
    if($converted.Count-eq 0){throw "SPDX omitted cataloged package: $($package.name)."}
  }
  if($RequiredFiles.Count-eq 0){throw 'No required application files.'}
  foreach($path in $RequiredFiles.Keys){
    $expected=([string]$RequiredFiles[$path]).ToLowerInvariant()
    if($expected-cnotmatch'^[0-9a-f]{64}$'){throw 'Invalid required file hash.'}
    $files=@($Syft.files|Where-Object { $_.location.path-ceq$path })
    if($files.Count-ne 1-or@($files[0].digests|Where-Object { $_.algorithm-ceq'sha256'-and$_.value-ceq$expected }).Count-ne 1){throw "Syft application file hash mismatch: $path."}
    $converted=@($Spdx.files|Where-Object { ($_.fileName-replace'^\./','/')-ceq$path })
    if($converted.Count-ne 1-or@($converted[0].checksums|Where-Object { $_.algorithm-ceq'SHA256'-and$_.checksumValue-ceq$expected }).Count-ne 1){throw "SPDX application file hash mismatch: $path."}
  }
  [pscustomobject]@{imageId=$ImageId;buildManifestDigest=$BuildMetadata['containerimage.digest'];archiveManifestDigest=$manifestId;debianPackages=$DebianInventory.Count;catalogedPackages=@($Syft.artifacts).Count;requiredFiles=$RequiredFiles.Count}
}
Export-ModuleMember -Function Assert-ViewerSbom
