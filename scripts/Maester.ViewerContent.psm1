#Requires -Version 7.6
Set-StrictMode -Version Latest

$script:ApprovedTemplateSha256 = 'A7B8DAE3D5932C3096FA98709AAAB9E9C1EBBFB83B5519E524B734EC751E3416'
$script:MaximumReportBytes = 20MB
$script:MaximumTemplateBytes = 8MB
$script:MaximumJsonBytes = 16MB
$script:MaximumOutputBytes = 64MB
$script:MaximumJsonDepth = 32
$script:MaximumJsonTokens = 1000000

if (-not ('MaesterViewer.Content.JsonCodec' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace MaesterViewer.Content
{
    public sealed class CappedMemoryStream : MemoryStream
    {
        private readonly long maximum;

        public CappedMemoryStream(long maximum) : base((int)Math.Min(maximum, 4096))
        {
            if (maximum < 1 || maximum > Int32.MaxValue) throw new ArgumentOutOfRangeException(nameof(maximum));
            this.maximum = maximum;
        }

        private void Check(int count)
        {
            if (count < 0 || Position > maximum - count) throw new InvalidDataException("Encoded report exceeds its limit.");
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            Check(count);
            base.Write(buffer, offset, count);
        }

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            Check(buffer.Length);
            base.Write(buffer);
        }

        public override void WriteByte(byte value)
        {
            Check(1);
            base.WriteByte(value);
        }
    }

    public static class JsonCodec
    {
        public static byte[] ValidateAndEncode(byte[] json, int maximumDepth, long maximumTokens, int maximumEncodedBytes)
        {
            if (json == null || json.Length == 0) throw new InvalidDataException("Report JSON is empty.");
            if (maximumDepth < 1 || maximumTokens < 1) throw new ArgumentOutOfRangeException();

            var options = new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = maximumDepth
            };
            var reader = new Utf8JsonReader(json, options);
            var names = new Stack<HashSet<string>>();
            long tokens = 0;
            bool first = true;
            while (reader.Read())
            {
                if (++tokens > maximumTokens) throw new InvalidDataException("Report JSON exceeds its token limit.");
                if (first)
                {
                    first = false;
                    if (reader.TokenType != JsonTokenType.StartObject) throw new InvalidDataException("Report JSON root must be an object.");
                }
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    names.Push(new HashSet<string>(StringComparer.Ordinal));
                }
                else if (reader.TokenType == JsonTokenType.PropertyName)
                {
                    if (names.Count == 0 || !names.Peek().Add(reader.GetString())) throw new InvalidDataException("Report JSON contains a duplicate property.");
                }
                else if (reader.TokenType == JsonTokenType.EndObject)
                {
                    if (names.Count == 0) throw new InvalidDataException("Report JSON is malformed.");
                    names.Pop();
                }
            }
            if (first || names.Count != 0) throw new InvalidDataException("Report JSON is incomplete.");

            string text = new UTF8Encoding(false, true).GetString(json);
            using (var output = new CappedMemoryStream(maximumEncodedBytes))
            {
                using (var writer = new Utf8JsonWriter(output, new JsonWriterOptions { Encoder = JavaScriptEncoder.Default }))
                {
                    writer.WriteStringValue(text);
                    writer.Flush();
                }
                return output.ToArray();
            }
        }
    }
}
'@
}

function Get-MaesterViewerSha256 {
  param([Parameter(Mandatory)][byte[]]$Bytes)
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function ConvertFrom-MaesterViewerStrictUtf8 {
  param([Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$Kind)
  if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw "$Kind must not contain a UTF-8 BOM." }
  try { [Text.UTF8Encoding]::new($false,$true).GetString($Bytes) }
  catch { throw "$Kind is not strict UTF-8." }
}

function Get-MaesterViewerLiteralCount {
  param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Literal)
  $count=0;$offset=0
  while(($offset=$Text.IndexOf($Literal,$offset,[StringComparison]::Ordinal))-ge 0){$count++;$offset+=$Literal.Length}
  $count
}

function ConvertTo-MaesterViewerExactLiteral {
  param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Old,[Parameter(Mandatory)][AllowEmptyString()][string]$New,[Parameter(Mandatory)][string]$Name)
  if((Get-MaesterViewerLiteralCount $Text $Old)-ne 1){throw "Approved template $Name boundary is invalid."}
  $Text.Replace($Old,$New,[StringComparison]::Ordinal)
}

function Get-MaesterViewerTemplateBoundary {
  param([Parameter(Mandatory)][string]$Template)
  $endPattern='EndOfJson:(?:"EndOfJson"|`EndOfJson`)\}'
  $ends=[regex]::Matches($Template,$endPattern)
  if($ends.Count-ne 1){throw 'Approved template JSON sentinel boundary is invalid.'}
  $end=$ends[0]
  $starts=[regex]::Matches($Template.Substring(0,$end.Index),'(?:var|const|let)\s+\w+\s*=')
  if($starts.Count-eq 0){throw 'Approved template JSON assignment boundary is invalid.'}
  $start=$starts[$starts.Count-1]
  [pscustomobject]@{
    Prefix=$Template.Substring(0,$start.Index+$start.Length)
    Suffix=$Template.Substring($end.Index+$end.Length)
  }
}

function ConvertTo-MaesterViewerReportProjectionCore {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$ReportBytes,
    [Parameter(Mandatory)][byte[]]$TemplateBytes,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedTemplateSha256,
    [int]$MaximumReportBytes=$script:MaximumReportBytes,
    [int]$MaximumTemplateBytes=$script:MaximumTemplateBytes,
    [int]$MaximumJsonBytes=$script:MaximumJsonBytes,
    [int]$MaximumOutputBytes=$script:MaximumOutputBytes,
    [int]$MaximumJsonDepth=$script:MaximumJsonDepth,
    [long]$MaximumJsonTokens=$script:MaximumJsonTokens
  )
  if($TemplateBytes.Length-eq 0-or$TemplateBytes.Length-gt$MaximumTemplateBytes){throw 'Viewer template size is invalid.'}
  if($ReportBytes.Length-eq 0-or$ReportBytes.Length-gt$MaximumReportBytes){throw 'Viewer report size is invalid.'}
  $templateSha256=Get-MaesterViewerSha256 $TemplateBytes
  if($templateSha256-cne$ExpectedTemplateSha256){throw 'Viewer template is not the approved Maester template.'}
  $template=ConvertFrom-MaesterViewerStrictUtf8 $TemplateBytes 'Viewer template'
  $report=ConvertFrom-MaesterViewerStrictUtf8 $ReportBytes 'Viewer report'
  $parts=Get-MaesterViewerTemplateBoundary $template

  $withoutWriterNewline=$null
  foreach($ending in @("`r`n","`n",'')){
    $expectedEnding=$parts.Suffix+$ending
    if($report.EndsWith($expectedEnding,[StringComparison]::Ordinal)){$withoutWriterNewline=$report.Substring(0,$report.Length-$ending.Length);break}
  }
  if($null-eq$withoutWriterNewline-or-not$withoutWriterNewline.StartsWith($parts.Prefix,[StringComparison]::Ordinal)-or-not$withoutWriterNewline.EndsWith($parts.Suffix,[StringComparison]::Ordinal)){throw 'Viewer report does not match the approved template boundaries.'}
  $jsonLength=$withoutWriterNewline.Length-$parts.Prefix.Length-$parts.Suffix.Length
  if($jsonLength-le 0){throw 'Viewer report JSON boundary is empty.'}
  $json=$withoutWriterNewline.Substring($parts.Prefix.Length,$jsonLength)
  $jsonBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($json)
  if($jsonBytes.Length-gt$MaximumJsonBytes){throw 'Viewer report JSON exceeds its limit.'}
  try{$encodedJsonBytes=[MaesterViewer.Content.JsonCodec]::ValidateAndEncode($jsonBytes,$MaximumJsonDepth,$MaximumJsonTokens,$MaximumOutputBytes)}
  catch{throw 'Viewer report JSON is invalid.'}
  $encodedJson=[Text.Encoding]::UTF8.GetString($encodedJsonBytes)

  $transform='function rRe(e){let t=e.indexOf(`:`),n=e.indexOf(`?`),r=e.indexOf(`#`),i=e.indexOf(`/`);return t===-1||i!==-1&&t>i||n!==-1&&t>n||r!==-1&&t>r||iRe.test(e.slice(0,t))?e:``}'
  if((Get-MaesterViewerLiteralCount $template 't.urlTransform||rRe')-ne 1-or(Get-MaesterViewerLiteralCount $template 'urlTransform:')-ne 0-or(Get-MaesterViewerLiteralCount $template '(J5,{')-ne 3){throw 'Approved template Markdown URL boundary is invalid.'}
  $qualified=ConvertTo-MaesterViewerExactLiteral $template $transform 'function rRe(){return}' 'Markdown URL transform'
  $qualified=ConvertTo-MaesterViewerExactLiteral $qualified '!t&&e.HelpUrl&&' '!1&&e.HelpUrl&&' 'help link'
  $qualified=ConvertTo-MaesterViewerExactLiteral $qualified 'a=i?.TenantLogos?.Banner' 'a=void 0' 'tenant banner'
  $favicon='    <link rel="icon" type="image/x-icon" href="https://maester.dev/img/favicon.ico" />'+"`n"
  $qualified=ConvertTo-MaesterViewerExactLiteral $qualified $favicon '' 'favicon'

  $qualifiedParts=Get-MaesterViewerTemplateBoundary $qualified
  $qualified=$qualifiedParts.Prefix+'JSON.parse('+$encodedJson+')'+$qualifiedParts.Suffix
  $scriptOpen='<script type="module" crossorigin>'
  if((Get-MaesterViewerLiteralCount $qualified $scriptOpen)-ne 1-or(Get-MaesterViewerLiteralCount $qualified '</script>')-ne 1){throw 'Approved template script boundary is invalid.'}
  $scriptStart=$qualified.IndexOf($scriptOpen,[StringComparison]::Ordinal)+$scriptOpen.Length
  $scriptEnd=$qualified.IndexOf('</script>',$scriptStart,[StringComparison]::Ordinal)
  $scriptBytes=[Text.Encoding]::UTF8.GetBytes($qualified.Substring($scriptStart,$scriptEnd-$scriptStart))
  $scriptHash=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($scriptBytes))
  $policy="default-src 'none'; script-src 'sha256-$scriptHash'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
  $meta="`n    <meta http-equiv=`"Content-Security-Policy`" content=`"$policy`" />"
  $qualified=ConvertTo-MaesterViewerExactLiteral $qualified '<head>' ('<head>'+$meta) 'head'
  $outputLength=[Text.Encoding]::UTF8.GetByteCount($qualified)
  if($outputLength-gt$MaximumOutputBytes){throw 'Qualified viewer report exceeds its limit.'}
  $htmlBytes=[Text.UTF8Encoding]::new($false).GetBytes($qualified)
  [pscustomobject]@{
    HtmlBytes=$htmlBytes
    HtmlLength=$htmlBytes.Length
    HtmlSha256=Get-MaesterViewerSha256 $htmlBytes
    TemplateSha256=$templateSha256
    ScriptSha256=$scriptHash
    ContentSecurityPolicy=$policy
    Policy=[pscustomobject]@{
      Name='maester-viewer-content-v1'
      MarkdownUrls='inert'
      HelpUrl='inert'
      TenantBanner='inert'
      ExternalFavicon='removed'
      JsonValuesPreserved=$true
    }
  }
}

function ConvertTo-MaesterViewerReportProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$ReportBytes,
    [Parameter(Mandatory)][byte[]]$TemplateBytes
  )
  ConvertTo-MaesterViewerReportProjectionCore -ReportBytes $ReportBytes -TemplateBytes $TemplateBytes -ExpectedTemplateSha256 $script:ApprovedTemplateSha256
}

function Assert-MaesterViewerContentTemplate {
  [CmdletBinding()]
  param([Parameter(Mandatory)][byte[]]$TemplateBytes)
  if($TemplateBytes.Length-eq 0-or$TemplateBytes.Length-gt$script:MaximumTemplateBytes){throw 'Viewer template size is invalid.'}
  if((Get-MaesterViewerSha256 $TemplateBytes)-cne$script:ApprovedTemplateSha256){throw 'Viewer template is not the approved Maester template.'}
  $null=ConvertFrom-MaesterViewerStrictUtf8 $TemplateBytes 'Viewer template'
}

function Assert-MaesterViewerReportProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$HtmlBytes,
    [Parameter(Mandatory)][byte[]]$TemplateBytes
  )
  try {
    Assert-MaesterViewerContentTemplate -TemplateBytes $TemplateBytes
    if($HtmlBytes.Length-eq 0-or$HtmlBytes.Length-gt$script:MaximumOutputBytes){throw 'invalid'}
    $candidate=ConvertFrom-MaesterViewerStrictUtf8 $HtmlBytes 'Qualified viewer report'
    $template=ConvertFrom-MaesterViewerStrictUtf8 $TemplateBytes 'Viewer template'

    $transform='function rRe(e){let t=e.indexOf(`:`),n=e.indexOf(`?`),r=e.indexOf(`#`),i=e.indexOf(`/`);return t===-1||i!==-1&&t>i||n!==-1&&t>n||r!==-1&&t>r||iRe.test(e.slice(0,t))?e:``}'
    $patched=ConvertTo-MaesterViewerExactLiteral $template $transform 'function rRe(){return}' 'Markdown URL transform'
    $patched=ConvertTo-MaesterViewerExactLiteral $patched '!t&&e.HelpUrl&&' '!1&&e.HelpUrl&&' 'help link'
    $patched=ConvertTo-MaesterViewerExactLiteral $patched 'a=i?.TenantLogos?.Banner' 'a=void 0' 'tenant banner'
    $favicon='    <link rel="icon" type="image/x-icon" href="https://maester.dev/img/favicon.ico" />'+"`n"
    $patched=ConvertTo-MaesterViewerExactLiteral $patched $favicon '' 'favicon'
    $parts=Get-MaesterViewerTemplateBoundary $patched

    $policyPattern='<head>\n    <meta http-equiv="Content-Security-Policy" content="default-src ''none''; script-src ''sha256-[A-Za-z0-9+/]{43}=''; style-src ''unsafe-inline''; img-src data:; font-src data:; connect-src ''none''; media-src ''none''; object-src ''none''; frame-src ''none''; worker-src ''none''; base-uri ''none''; form-action ''none''" />'
    $policyMatches=[regex]::Matches($candidate,$policyPattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if($policyMatches.Count-ne 1){throw 'invalid'}
    $withoutPolicy=$candidate.Remove($policyMatches[0].Index,$policyMatches[0].Length).Insert($policyMatches[0].Index,'<head>')
    $prefix=$parts.Prefix+'JSON.parse('
    $suffix=')'+$parts.Suffix
    if(-not$withoutPolicy.StartsWith($prefix,[StringComparison]::Ordinal)-or-not$withoutPolicy.EndsWith($suffix,[StringComparison]::Ordinal)){throw 'invalid'}
    $literalLength=$withoutPolicy.Length-$prefix.Length-$suffix.Length
    if($literalLength-le 1){throw 'invalid'}
    $literal=$withoutPolicy.Substring($prefix.Length,$literalLength)
    try {
      $literalDocument=[Text.Json.JsonDocument]::Parse($literal)
      try {
        if($literalDocument.RootElement.ValueKind-ne[Text.Json.JsonValueKind]::String){throw 'invalid'}
        $rawJson=$literalDocument.RootElement.GetString()
      } finally {$literalDocument.Dispose()}
    } catch {throw 'invalid'}
    if([string]::IsNullOrEmpty($rawJson)){throw 'invalid'}
    $rawParts=Get-MaesterViewerTemplateBoundary $template
    $rawReport=[Text.UTF8Encoding]::new($false).GetBytes($rawParts.Prefix+$rawJson+$rawParts.Suffix)
    $rebuilt=ConvertTo-MaesterViewerReportProjection -ReportBytes $rawReport -TemplateBytes $TemplateBytes
    if($rebuilt.HtmlBytes.Length-ne$HtmlBytes.Length-or-not[Security.Cryptography.CryptographicOperations]::FixedTimeEquals($rebuilt.HtmlBytes,$HtmlBytes)){throw 'invalid'}
    [pscustomobject]@{ Qualified=$true; HtmlLength=[long]$HtmlBytes.Length; HtmlSha256=(Get-MaesterViewerSha256 $HtmlBytes); TemplateSha256=$script:ApprovedTemplateSha256; Policy='maester-viewer-content-v1' }
  } catch {throw 'Viewer report is not an approved qualified projection.'}
}

Export-ModuleMember -Function ConvertTo-MaesterViewerReportProjection, Assert-MaesterViewerContentTemplate, Assert-MaesterViewerReportProjection
