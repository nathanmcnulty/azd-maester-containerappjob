#Requires -Version 7.6
function Get-MaesterViewerTestTemplateBytes {
  $path=$env:MAESTER_VIEWER_TEMPLATE_PATH
  if([string]::IsNullOrWhiteSpace($path)-or-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'The exact Maester viewer test template is unavailable.'}
  $bytes=[IO.File]::ReadAllBytes($path)
  if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))-cne'A7B8DAE3D5932C3096FA98709AAAB9E9C1EBBFB83B5519E524B734EC751E3416'){
    throw 'The Maester viewer test template hash is invalid.'
  }
  $bytes
}

function New-MaesterViewerRawTestReport {
  param([Parameter(Mandatory)][byte[]]$TemplateBytes,[Parameter(Mandatory)][string]$Json)
  $utf8=[Text.UTF8Encoding]::new($false,$true);$template=$utf8.GetString($TemplateBytes)
  $end=[regex]::Match($template,'EndOfJson:(?:"EndOfJson"|`EndOfJson`)\}')
  $starts=[regex]::Matches($template.Substring(0,$end.Index),'(?:var|const|let)\s+\w+\s*=')
  if(-not$end.Success-or$starts.Count-eq 0){throw 'The Maester viewer test template boundary is invalid.'}
  $start=$starts[$starts.Count-1]
  $prefix=$template.Substring(0,$start.Index+$start.Length);$suffix=$template.Substring($end.Index+$end.Length)
  $utf8.GetBytes($prefix+$Json+$suffix)
}

function New-MaesterViewerQualifiedTestReport {
  param([Parameter(Mandatory)][byte[]]$TemplateBytes,[Parameter(Mandatory)][string]$Json)
  (ConvertTo-MaesterViewerReportProjection -ReportBytes (New-MaesterViewerRawTestReport $TemplateBytes $Json) -TemplateBytes $TemplateBytes).HtmlBytes
}
