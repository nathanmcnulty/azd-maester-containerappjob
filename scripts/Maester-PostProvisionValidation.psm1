Set-StrictMode -Version Latest

function ConvertFrom-MaesterBooleanSetting {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value.Trim() -ieq 'true') { return $true }
  if ($Value.Trim() -ieq 'false') { return $false }
  throw "$Name must be 'true' or 'false' when set."
}

function Invoke-MaesterPostProvisionValidation {
  [CmdletBinding()]
  param(
    [AllowNull()]
    [string]$JobTriggerType,

    [AllowNull()]
    [string]$RunValidation,

    [AllowNull()]
    [string]$RequireNoMail,

    [Parameter(Mandatory = $true)]
    [scriptblock]$ValidationAction
  )

  $trigger = if ([string]::IsNullOrWhiteSpace($JobTriggerType)) { 'Manual' } else { $JobTriggerType.Trim() }
  if ($trigger -cnotin @('Manual', 'Schedule')) {
    throw "Unsupported JOB_TRIGGER_TYPE '$trigger'; expected Manual or Schedule."
  }

  $runOptIn = ConvertFrom-MaesterBooleanSetting -Name 'MAESTER_RUN_POSTPROVISION_VALIDATION' -Value $RunValidation
  $requireNoMailValue = ConvertFrom-MaesterBooleanSetting -Name 'MAESTER_REQUIRE_NO_MAIL' -Value $RequireNoMail
  $shouldRun = ($trigger -ceq 'Schedule') -or $runOptIn

  if (-not $shouldRun) {
    return [pscustomobject]@{
      ValidationSkipped = $true
      ValidationPassed  = $false
      ExecutionName     = 'n/a'
      FinalStatus       = 'NotStarted'
      CompletedAt       = 'n/a'
      SkipReason        = 'Manual trigger; MAESTER_RUN_POSTPROVISION_VALIDATION is not true.'
    }
  }

  $validationOptions = @{ RequireNoMail = $requireNoMailValue }
  $actionResults = @(& $ValidationAction $validationOptions)
  if ($actionResults.Count -ne 1 -or $null -eq $actionResults[0]) {
    throw 'The postprovision validation action did not return exactly one result.'
  }

  $result = $actionResults[0]
  $properties = @{}
  if ($result -is [System.Collections.IDictionary]) {
    foreach ($key in $result.Keys) { $properties[[string]$key] = $result[$key] }
  }
  else {
    foreach ($property in $result.PSObject.Properties) { $properties[$property.Name] = $property.Value }
  }
  $properties['ValidationSkipped'] = $false
  $properties['SkipReason'] = $null
  return [pscustomobject]$properties
}

Export-ModuleMember -Function Invoke-MaesterPostProvisionValidation
