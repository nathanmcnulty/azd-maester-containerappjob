#Requires -Version 7.6
BeforeAll {
  Import-Module (Join-Path $PSScriptRoot 'ViewerSbom.psm1') -Force
  function New-SbomFixture {
    $config=[Text.Encoding]::UTF8.GetBytes('{"architecture":"amd64","os":"linux"}')
    $imageId='sha256:'+([Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($config)))
    $manifest=[Text.Encoding]::UTF8.GetBytes(('{"config":{"digest":"'+$imageId+'"}}'))
    $manifestId='sha256:'+([Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($manifest)))
    $hash='a'*64
    @{
      ImageId=$imageId
      BuildMetadata=@{'containerimage.config.digest'=$imageId;'containerimage.digest'=$manifestId;'containerimage.descriptor'=@{digest=$manifestId};'buildx.build.provenance'=@{buildType='https://mobyproject.org/buildkit@v1'};'buildx.build.ref'='builder/ref'}
      Syft=@{
        descriptor=@{name='syft';version='1.54.1'}
        source=@{type='image';metadata=@{imageID=$imageId;config=[Convert]::ToBase64String($config);manifest=[Convert]::ToBase64String($manifest);manifestDigest=$manifestId;os='linux';architecture='amd64'}}
        artifacts=@(
          @{name='libc6';version='2.36';type='deb';metadata=@{architecture='amd64'};purl='pkg:deb/debian/libc6@2.36?arch=amd64'},
          @{name='System.Management.Automation';version='7.6.6';type='dotnet';purl='pkg:nuget/System.Management.Automation@7.6.6';locations=@(@{path='/opt/microsoft/powershell/7/pwsh.deps.json'})}
        )
        files=@(@{location=@{path='/opt/viewer.ps1'};digests=@(@{algorithm='sha256';value=$hash})})
      }
      Spdx=@{
        spdxVersion='SPDX-2.3'
        relationships=@(@{spdxElementId='SPDXRef-DOCUMENT';relationshipType='DESCRIBES';relatedSpdxElement='SPDXRef-image'})
        packages=@(
          @{SPDXID='SPDXRef-image';primaryPackagePurpose='CONTAINER';versionInfo=$manifestId;checksums=@(@{algorithm='SHA256';checksumValue=$manifestId.Substring(7)})},
          @{versionInfo='2.36';externalRefs=@(@{referenceType='purl';referenceLocator='pkg:deb/debian/libc6@2.36?arch=amd64'})},
          @{versionInfo='7.6.6';externalRefs=@(@{referenceType='purl';referenceLocator='pkg:nuget/System.Management.Automation@7.6.6'})}
        )
        files=@(@{fileName='./opt/viewer.ps1';checksums=@(@{algorithm='SHA256';checksumValue=$hash})})
      }
      DebianInventory=@("libc6`t2.36`tamd64")
      RequiredFiles=@{'/opt/viewer.ps1'=$hash}
      RuntimePackage='System.Management.Automation'
      RuntimeVersion='7.6.6'
      RuntimeLocations=@('/opt/microsoft/powershell/7/pwsh.deps.json','/opt/microsoft/powershell/7/System.Management.Automation.dll')
    }
  }
}
Describe 'Runtime SBOM evidence binding' {
  It 'binds both formats to the tested config, package inventory and application bytes' {
    $fixture=New-SbomFixture
    $result=Assert-ViewerSbom @fixture
    $result.imageId|Should -BeExactly $fixture.ImageId
    $result.debianPackages|Should -Be 1
    $result.requiredFiles|Should -Be 1
  }
  It 'rejects a different build even when its manifest field looks valid' {
    $fixture=New-SbomFixture
    $fixture.BuildMetadata['containerimage.config.digest']='sha256:'+('b'*64)
    {Assert-ViewerSbom @fixture}|Should -Throw '*Build config digest*'
  }
  It 'rejects self-declared image identity with different raw config bytes' {
    $fixture=New-SbomFixture
    $fixture.Syft.source.metadata.config=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
    {Assert-ViewerSbom @fixture}|Should -Throw '*raw config*'
  }
  It 'rejects an SPDX document describing another scanned manifest' {
    $fixture=New-SbomFixture
    $fixture.Spdx.packages[0].versionInfo='sha256:'+('b'*64)
    {Assert-ViewerSbom @fixture}|Should -Throw '*SPDX root*'
  }
  It 'requires the independent Debian version and architecture' {
    $fixture=New-SbomFixture
    $fixture.Syft.artifacts[0].metadata.architecture='arm64'
    {Assert-ViewerSbom @fixture}|Should -Throw '*Debian package*'
  }
  It 'requires copied runtime coverage in addition to operating-system packages' {
    $fixture=New-SbomFixture
    $fixture.Syft.artifacts=$fixture.Syft.artifacts[0]
    {Assert-ViewerSbom @fixture}|Should -Throw '*copied runtime package*'
  }
  It 'rejects package loss during SPDX conversion' {
    $fixture=New-SbomFixture
    $fixture.Spdx.packages=$fixture.Spdx.packages[0..1]
    {Assert-ViewerSbom @fixture}|Should -Throw '*SPDX omitted*'
  }
  It 'rejects the expected runtime package reported only at an unrelated path' {
    $fixture=New-SbomFixture
    $fixture.Syft.artifacts[1].locations[0].path='/tmp/unrelated/pwsh.deps.json'
    {Assert-ViewerSbom @fixture}|Should -Throw '*runtime location*'
  }
  It 'requires unowned application files with real SHA256 digests' {
    $fixture=New-SbomFixture
    $fixture.Syft.files[0].digests=@(@{algorithm='sha1';value='0'*40})
    {Assert-ViewerSbom @fixture}|Should -Throw '*Syft application file hash*'
  }
  It 'rejects file-byte changes in the portable SPDX output' {
    $fixture=New-SbomFixture
    $fixture.Spdx.files[0].checksums[0].checksumValue='b'*64
    {Assert-ViewerSbom @fixture}|Should -Throw '*SPDX application file hash*'
  }
}
