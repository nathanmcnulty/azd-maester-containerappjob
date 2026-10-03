Describe 'Postprovision Maester job selection' {
  BeforeAll {
    $resolver = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Resolve-MaesterContainerJob.ps1'
    $tags = [pscustomobject]@{ environment = 'verylongenvironment'; managedBy = 'azd'; workload = 'maester' }
  }

  It 'uses the exact Bicep output name when it matches the complete solution tags' {
    $payload = [pscustomobject]@{ value = @(
      [pscustomobject]@{ name = 'unrelated'; tags = [pscustomobject]@{ environment = 'other'; managedBy = 'azd'; workload = 'maester' } },
      [pscustomobject]@{ name = 'caj-maester-verylongen-abc123'; tags = $tags }
    ) }

    $job = & $resolver -JobsPayload $payload -EnvironmentName 'verylongenvironment' `
      -ExpectedName 'caj-maester-verylongen-abc123'
    $job.name | Should -Be 'caj-maester-verylongen-abc123'
  }

  It 'rejects a sole unrelated job' {
    $payload = [pscustomobject]@{ value = @(
      [pscustomobject]@{ name = 'unrelated' }
    ) }
    { & $resolver -JobsPayload $payload -EnvironmentName 'verylongenvironment' } |
      Should -Throw '*Expected exactly one Maester Container App Job*found 0*'
  }

  It 'rejects multiple matching jobs' {
    $payload = [pscustomobject]@{ value = @(
      [pscustomobject]@{ name = 'job-one'; tags = $tags },
      [pscustomobject]@{ name = 'job-two'; tags = $tags }
    ) }
    { & $resolver -JobsPayload $payload -EnvironmentName 'verylongenvironment' } |
      Should -Throw '*Expected exactly one Maester Container App Job*found 2*'
  }

  It 'rejects a stale output name even when another tagged job exists' {
    $payload = [pscustomobject]@{ value = @([pscustomobject]@{ name = 'actual-job'; tags = $tags }) }
    { & $resolver -JobsPayload $payload -EnvironmentName 'verylongenvironment' -ExpectedName 'stale-job' } |
      Should -Throw '*Expected exactly one Maester Container App Job named*found 0*'
  }

  It 'rejects a partial paginated job list' {
    $payload = [pscustomobject]@{
      value = @([pscustomobject]@{ name = 'job-one'; tags = $tags })
      nextLink = 'https://management.azure.com/next-page'
    }
    { & $resolver -JobsPayload $payload -EnvironmentName 'verylongenvironment' } |
      Should -Throw '*Container App Job list is incomplete*'
  }
}
