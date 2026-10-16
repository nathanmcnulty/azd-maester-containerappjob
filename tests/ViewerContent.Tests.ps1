#Requires -Version 7.6
BeforeAll {
  $script:modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Maester.ViewerContent.psm1'
  Import-Module $modulePath -Force
  $script:transform='function rRe(e){let t=e.indexOf(`:`),n=e.indexOf(`?`),r=e.indexOf(`#`),i=e.indexOf(`/`);return t===-1||i!==-1&&t>i||n!==-1&&t>n||r!==-1&&t>r||iRe.test(e.slice(0,t))?e:``}'
  $script:template=@"
<!DOCTYPE html>
<html><head>
    <link rel="icon" type="image/x-icon" href="https://maester.dev/img/favicon.ico" />
<script type="module" crossorigin>$transform;function nRe(e,t){let c=t.urlTransform||rRe;return c}function J5(){};(J5,{});(J5,{});(J5,{});function sinks(e,t,i){let n=()=>{};!t&&e.HelpUrl&&n(new URL(e.HelpUrl).hostname);let a=i?.TenantLogos?.Banner;return a}var Ns={EndOfJson:`"EndOfJson`"};function after(){return true}</script>
<style>body{color:black}</style></head><body></body></html>
"@ -replace "`r`n","`n"
  $script:utf8=[Text.UTF8Encoding]::new($false,$true)
  $script:templateBytes=$utf8.GetBytes($template)
  $script:templateHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($templateBytes))
  function Get-TestReportByte([string]$Json,[string]$Ending='') {
    $utf8.GetBytes(($template.Replace('{EndOfJson:"EndOfJson"}',$Json,[StringComparison]::Ordinal))+$Ending)
  }
  function Invoke-SyntheticConversion([byte[]]$ReportBytes,[hashtable]$Limits=@{}) {
    InModuleScope Maester.ViewerContent -Parameters @{report=$ReportBytes;template=$templateBytes;hash=$templateHash;limits=$Limits} {
      $parameters=@{ReportBytes=$report;TemplateBytes=$template;ExpectedTemplateSha256=$hash}
      foreach($key in $limits.Keys){$parameters[$key]=$limits[$key]}
      ConvertTo-MaesterViewerReportProjectionCore @parameters
    }
  }
  function Get-EmbeddedJson([string]$Html) {
    $prefix='var Ns=JSON.parse('
    $start=$Html.IndexOf($prefix,[StringComparison]::Ordinal)+$prefix.Length
    $end=$Html.IndexOf(');function after',$start,[StringComparison]::Ordinal)
    $literal=$Html.Substring($start,$end-$start)
    ([Text.Json.JsonDocument]::Parse($literal)).RootElement.GetString()
  }
}

Describe 'Maester viewer content qualification' {
  It 'regenerates and accepts only the exact public qualified bytes from the approved template' {
    $exactTemplate=[IO.File]::ReadAllBytes($env:MAESTER_VIEWER_TEMPLATE_PATH)
    $exactText=[Text.UTF8Encoding]::new($false,$true).GetString($exactTemplate)
    $end=[regex]::Match($exactText,'EndOfJson:(?:"EndOfJson"|`EndOfJson`)\}');$starts=[regex]::Matches($exactText.Substring(0,$end.Index),'(?:var|const|let)\s+\w+\s*=');$start=$starts[$starts.Count-1]
    $raw=[Text.UTF8Encoding]::new($false).GetBytes($exactText.Substring(0,$start.Index+$start.Length)+'{"Mixed":"</script> & < > \\ / \"    ","EndOfJson":"EndOfJson","OutputFiles":["report.html"]}'+$exactText.Substring($end.Index+$end.Length))
    $qualified=ConvertTo-MaesterViewerReportProjection -ReportBytes $raw -TemplateBytes $exactTemplate
    $receipt=Assert-MaesterViewerReportProjection -HtmlBytes $qualified.HtmlBytes -TemplateBytes $exactTemplate
    $receipt.Qualified|Should -BeTrue;$receipt.HtmlSha256|Should -BeExactly $qualified.HtmlSha256
    $tampered=[byte[]]$qualified.HtmlBytes.Clone();$tampered[100]=[byte]($tampered[100]-bxor 1)
    {Assert-MaesterViewerReportProjection -HtmlBytes $tampered -TemplateBytes $exactTemplate}|Should -Throw '*approved qualified*'
  }

  It 'preserves JSON values while disabling every approved URL sink' {
    $json='{"TenantName":"Synthetic caf\u00e9 \u6771\u4eac","HelpUrl":"javascript:alert(1)","TenantLogos":{"Banner":"https://example.invalid/logo"},"ResultDetail":{"TestResult":"[link](https://example.invalid) ![image](https://example.invalid/x)"},"EndOfJson":"EndOfJson"}'
    $result=Invoke-SyntheticConversion (Get-TestReportByte $json)
    $html=$utf8.GetString($result.HtmlBytes)
    (Get-EmbeddedJson $html)|Should -BeExactly $json
    $html|Should -Match ([regex]::Escape('function rRe(){return}'))
    $html|Should -Match ([regex]::Escape('!1&&e.HelpUrl&&'))
    $html|Should -Match ([regex]::Escape('a=void 0'))
    $html|Should -Not -Match 'maester\.dev/img/favicon'
    $html.IndexOf('http-equiv="Content-Security-Policy"',[StringComparison]::Ordinal)|Should -BeLessThan $html.IndexOf('<script',[StringComparison]::Ordinal)
    $result.TemplateSha256|Should -BeExactly $templateHash
    $result.HtmlSha256|Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result.HtmlBytes)))
    $result.HtmlLength|Should -Be $result.HtmlBytes.Length
    $result.Policy.Name|Should -BeExactly 'maester-viewer-content-v1'
    $result.Policy.MarkdownUrls|Should -BeExactly 'inert'
    $result.Policy.HelpUrl|Should -BeExactly 'inert'
    $result.Policy.TenantBanner|Should -BeExactly 'inert'
    $result.Policy.ExternalFavicon|Should -BeExactly 'removed'
    $result.Policy.JsonValuesPreserved|Should -BeTrue
  }

  It 'encodes script terminators and Unicode separators as data' {
    $separators=[string][char]0x2028+[char]0x2029
    $json='{"Text":"</ScRiPt><SCRIPT>globalThis.mixed=1</SCRIPT><!--comment-->&<> \"quoted\" / \\\\ {SEPARATORS}","Nested":{"Value":"A&B<C>D"},"EndOfJson":"EndOfJson","OutputFiles":["report.html"]}'.Replace('{SEPARATORS}',$separators,[StringComparison]::Ordinal)
    $result=Invoke-SyntheticConversion (Get-TestReportByte $json)
    $html=$utf8.GetString($result.HtmlBytes)
    ([regex]::Matches($html,'<script\b')).Count|Should -Be 1
    $html|Should -Not -Match '<SCRIPT>globalThis\.mixed'
    (Get-EmbeddedJson $html)|Should -BeExactly $json
  }

  It 'preserves supported producer shapes without treating the template marker as data schema' -ForEach @(
    '{"Name":"with marker","EndOfJson":"EndOfJson","OutputFiles":["report.html"]}',
    '{"Name":"without marker","OutputFiles":[]}'
  ) {
    $result=Invoke-SyntheticConversion (Get-TestReportByte $_)
    (Get-EmbeddedJson ($utf8.GetString($result.HtmlBytes)))|Should -BeExactly $_
  }

  It 'binds the CSP script hash to the reconstructed module' {
    $result=Invoke-SyntheticConversion (Get-TestReportByte '{"EndOfJson":"EndOfJson"}')
    $html=$utf8.GetString($result.HtmlBytes)
    $open='<script type="module" crossorigin>';$start=$html.IndexOf($open)+$open.Length;$end=$html.IndexOf('</script>',$start)
    $actual=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($html.Substring($start,$end-$start))))
    $result.ScriptSha256|Should -BeExactly $actual
    $result.ContentSecurityPolicy|Should -Match ([regex]::Escape("script-src 'sha256-$actual'"))
    $result.ContentSecurityPolicy|Should -Match "default-src 'none'"
    $result.ContentSecurityPolicy|Should -Match "connect-src 'none'"
  }

  It 'accepts only no writer newline or one LF or CRLF' -ForEach @('',"`n","`r`n") {
    $result=Invoke-SyntheticConversion (Get-TestReportByte '{"EndOfJson":"EndOfJson"}' $_)
    $result.HtmlLength|Should -BeGreaterThan 0
  }

  It 'rejects additional trailing content' -ForEach @("`n`n","`r`n`r`n",'<!--tail-->') {
    {Invoke-SyntheticConversion (Get-TestReportByte '{"EndOfJson":"EndOfJson"}' $_)}|Should -Throw
  }

  It 'recursively rejects duplicate JSON properties with a closed error' -ForEach @(
    '{"A":1,"A":2,"EndOfJson":"EndOfJson"}',
    '{"Nested":{"A":1,"A":2},"EndOfJson":"EndOfJson"}'
  ) {
    {Invoke-SyntheticConversion (Get-TestReportByte $_)}|Should -Throw 'Viewer report JSON is invalid.'
  }

  It 'rejects malformed roots, comments, and depth with a closed error' -ForEach @(
    @{Json='[]';Limits=@{}},
    @{Json='{"A":1/*DoNotRevealParserDetail*/}';Limits=@{}},
    @{Json='{"A":{"B":{"C":1}},"EndOfJson":"EndOfJson"}';Limits=@{MaximumJsonDepth=2}}
  ) {
    {Invoke-SyntheticConversion (Get-TestReportByte $_.Json) $_.Limits}|Should -Throw 'Viewer report JSON is invalid.'
  }

  It 'rejects token and escaped-output growth before returning bytes' {
    {Invoke-SyntheticConversion (Get-TestReportByte '{"A":[1,2,3],"EndOfJson":"EndOfJson"}') @{MaximumJsonTokens=4}}|Should -Throw 'Viewer report JSON is invalid.'
    {Invoke-SyntheticConversion (Get-TestReportByte '{"A":"<<<<<<<<<<<<<<<<<<<<","EndOfJson":"EndOfJson"}') @{MaximumOutputBytes=40}}|Should -Throw 'Viewer report JSON is invalid.'
  }

  It 'enforces the template byte cap before hashing' {
    $report=Get-TestReportByte '{"A":1}'
    InModuleScope Maester.ViewerContent -Parameters @{report=$report;template=$templateBytes} {
      {ConvertTo-MaesterViewerReportProjectionCore -ReportBytes $report -TemplateBytes $template -ExpectedTemplateSha256 ('0'*64) -MaximumTemplateBytes ($template.Length-1)}|Should -Throw 'Viewer template size is invalid.'
    }
  }

  It 'enforces the report byte cap before decoding' {
    $report=Get-TestReportByte '{"A":1}'
    {Invoke-SyntheticConversion $report @{MaximumReportBytes=$report.Length-1}}|Should -Throw 'Viewer report size is invalid.'
  }

  It 'enforces the extracted JSON byte cap' {
    {Invoke-SyntheticConversion (Get-TestReportByte '{"A":1}') @{MaximumJsonBytes=1}}|Should -Throw 'Viewer report JSON exceeds its limit.'
  }

  It 'rejects BOM and invalid UTF-8 inputs' {
    $report=Get-TestReportByte '{"EndOfJson":"EndOfJson"}'
    {Invoke-SyntheticConversion ([byte[]](0xEF,0xBB,0xBF)+$report)}|Should -Throw '*BOM*'
    $bad=[byte[]]($report[0..10]+0xC3,0x28+$report[11..($report.Length-1)])
    {Invoke-SyntheticConversion $bad}|Should -Throw '*strict UTF-8*'
  }

  It 'rejects template, report boundary, and exact patch drift' {
    $report=Get-TestReportByte '{"EndOfJson":"EndOfJson"}'
    InModuleScope Maester.ViewerContent -Parameters @{report=$report;template=$templateBytes;hash=$templateHash} {
      {ConvertTo-MaesterViewerReportProjectionCore -ReportBytes $report -TemplateBytes $template -ExpectedTemplateSha256 ('0'*64)}|Should -Throw '*approved Maester template*'
      $driftText=([Text.Encoding]::UTF8.GetString($template)).Replace('!t&&e.HelpUrl&&','e.HelpUrl&&')
      $drift=[Text.UTF8Encoding]::new($false).GetBytes($driftText)
      $driftHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($drift))
      $driftReport=[Text.UTF8Encoding]::new($false).GetBytes($driftText.Replace('{EndOfJson:"EndOfJson"}','{"EndOfJson":"EndOfJson"}'))
      {ConvertTo-MaesterViewerReportProjectionCore -ReportBytes $driftReport -TemplateBytes $drift -ExpectedTemplateSha256 $driftHash}|Should -Throw '*help link boundary*'
    }
    $changed=[byte[]]$report.Clone();$changed[0]=[byte][char]'X'
    {Invoke-SyntheticConversion $changed}|Should -Throw '*template boundaries*'
  }

  It 'does not expose an override for the public approved template hash' {
    (Get-Command ConvertTo-MaesterViewerReportProjection).Parameters.Keys|Should -Not -Contain 'ExpectedTemplateSha256'
    {ConvertTo-MaesterViewerReportProjection -ReportBytes (Get-TestReportByte '{"EndOfJson":"EndOfJson"}') -TemplateBytes $templateBytes}|Should -Throw '*approved Maester template*'
  }
}
