[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  $JobsPayload,

  [Parameter(Mandatory = $true)]
  [string]$EnvironmentName,

  [string]$ExpectedName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($JobsPayload.PSObject.Properties['nextLink'] -and $JobsPayload.nextLink) {
  throw 'Container App Job list is incomplete. Resolve the full list before selecting a job.'
}

$matches = @($JobsPayload.value | Where-Object {
    $tags = if ($_.PSObject.Properties['tags']) { $_.tags } else { $null }
    $tags -and $tags.PSObject.Properties['environment'] -and
    $tags.PSObject.Properties['managedBy'] -and
    $tags.PSObject.Properties['workload'] -and
    $tags.environment -eq $EnvironmentName.ToLowerInvariant() -and
    $tags.managedBy -eq 'azd' -and $tags.workload -eq 'maester' -and
    ([string]::IsNullOrWhiteSpace($ExpectedName) -or $_.name -eq $ExpectedName)
  })

if ($matches.Count -ne 1) {
  $target = if ($ExpectedName) { " named '$ExpectedName'" } else { '' }
  throw "Expected exactly one Maester Container App Job$target for environment '$EnvironmentName'; found $($matches.Count)."
}

return $matches[0]
