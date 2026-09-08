# higgs-voice-kit (Windows): generate narration with the anchor pipeline on CUDA.
# Usage: powershell -ExecutionPolicy Bypass -File runtime\generate-anchor.ps1 -VoiceId my_voice -TextFile script.txt
param(
    [Parameter(Mandatory = $true)][string]$VoiceId,
    [Parameter(Mandatory = $true)][string]$TextFile,
    [ValidateSet('cuda', 'cpu', 'vulkan', 'best')][string]$Backend = 'cuda',
    [ValidateSet('anchor', 'raw')][string]$Mode = 'anchor',
    [int]$Seed = 42,
    [double]$Temperature = 0.66,
    [int]$TopK = 24,
    [double]$TopP = 0.8,
    [int]$MaxTokens = 4096,
    [int]$Chunk = 200,
    [int]$Threads = 8
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent
$Cli = Join-Path $Root 'runtime\audiocpp_cli.exe'
$Model = Join-Path $Root 'models\higgs-audio-v3-tts-4b-q8_0.gguf'
$Ladder = @(0, 1000, 7777)

if (-not (Test-Path $Cli)) { throw "audiocpp_cli.exe not found at $Cli" }
if (-not (Test-Path $Model)) { throw "model not found at $Model (run scripts\download-model.sh or download manually)" }

$voices = (Get-Content (Join-Path $Root 'config\voices.json') -Raw -Encoding UTF8 | ConvertFrom-Json).voices
$voice = $voices | Where-Object { $_.id -eq $VoiceId } | Select-Object -First 1
if (-not $voice) { throw "voice '$VoiceId' not found in config\voices.json" }
$voicePath = $voice.path
if (-not [IO.Path]::IsPathRooted($voicePath)) { $voicePath = Join-Path $Root $voicePath }
if (-not (Test-Path $voicePath)) { throw "reference wav not found: $voicePath" }
$refText = $voice.reference_text
$language = $voice.language
$anchorLang = if ($language) { $language } else { 'ko' }
$anchorFile = Join-Path $Root ("config\anchor.{0}.txt" -f $anchorLang)
if (-not (Test-Path $anchorFile)) { throw "anchor sentence file not found: $anchorFile (copy config\anchor.en.txt and translate it)" }
$AnchorText = [IO.File]::ReadAllText($anchorFile, [Text.Encoding]::UTF8).Trim()

$text = ([IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8) -replace '(?m)^\s*#.*$', '' -replace '\s+', ' ' -replace '"', '').Trim()
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($d in 'outputs', 'logs', 'cache\anchors') { New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }

function Invoke-Tts([string]$Text, [string]$Ref, [string]$RefText, [int]$UseSeed, [int]$UseMaxTokens, [string]$Out, [string]$Log) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $parts = @(
        '--backend', $Backend, '--threads', $Threads,
        '--task', 'tts', '--family', 'higgs_audio_tts', '--model', ('"' + $Model + '"'),
        '--text', ('"' + $Text + '"'), '--voice-ref', ('"' + $Ref + '"'), '--reference-text', ('"' + $RefText + '"'),
        '--seed', $UseSeed, '--temperature', $Temperature.ToString($inv), '--top-k', $TopK, '--top-p', $TopP.ToString($inv),
        '--max-tokens', $UseMaxTokens, '--text-chunk-size', $Chunk, '--out', ('"' + $Out + '"')
    )
    if ($language) { $parts += @('--language', $language) }
    $p = Start-Process -FilePath $Cli -ArgumentList ($parts -join ' ') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    return $p.ExitCode
}

function Invoke-Ladder([string]$Text, [string]$Ref, [string]$RefText, [string]$Out, [string]$LogBase) {
    foreach ($off in $Ladder) {
        $s = $Seed + $off
        $log = "$LogBase-seed$s.log"
        $code = Invoke-Tts $Text $Ref $RefText $s $MaxTokens $Out $log
        if ($code -eq 0 -and (Test-Path $Out)) { Write-Host "generated with seed $s"; return }
        $all = (Get-Content $log, "$log.err" -Raw -ErrorAction SilentlyContinue) -join "`n"
        if ($all -match 'max_tokens before EOC') { Write-Warning "seed $s stopped before end of content, trying another seed"; continue }
        throw "generation failed (exit $code), see $log"
    }
    throw 'all seeds stopped before end of content; shorten the text or lower -Chunk'
}

$ref = $voicePath
$refTextUsed = $refText
if ($Mode -eq 'anchor') {
    $anchor = Join-Path $Root ("cache\anchors\anchor_{0}_seed{1}.wav" -f $VoiceId, $Seed)
    if (-not (Test-Path $anchor)) {
        Write-Host "building voice anchor for '$VoiceId' (one time)"
        Invoke-Ladder $AnchorText $voicePath $refText $anchor (Join-Path $Root "logs\anchor-$VoiceId-$stamp")
    }
    $ref = $anchor
    $refTextUsed = $AnchorText
}

$out = Join-Path $Root "outputs\higgs-$stamp.wav"
Invoke-Ladder $text $ref $refTextUsed $out (Join-Path $Root "logs\generate-$stamp")
Write-Host $out
