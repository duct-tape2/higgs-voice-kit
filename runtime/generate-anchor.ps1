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
    [int]$Threads = 8,
    [int]$GapMs = 250,
    [string]$Chunking = 'smart'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent
$Cli = Join-Path $Root 'runtime\audiocpp_cli.exe'
$Model = Join-Path $Root 'models\higgs-audio-v3-tts-4b-q8_0.gguf'
$Ladder = @(0, 1000, 7777)

if (-not (Test-Path $Cli)) { throw "audiocpp_cli.exe not found at $Cli" }
if (-not (Test-Path $Model)) { throw "model not found at $Model (run scripts\download-model.sh or download manually)" }

try {
    $data = Get-Content (Join-Path $Root 'config\voices.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $voices = $data.voices
} catch {
    throw "Failed to parse config\voices.json: $($_.Exception.Message)"
}
if (-not $voices) { throw "No voices defined in config\voices.json" }
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

$text = ([IO.File]::ReadAllText($TextFile, [Text.Encoding]::UTF8) -replace '(?m)^\s*#.*$', '' -replace '\s+', ' ').Trim()
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($d in 'outputs', 'logs', 'cache\anchors') { New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }

function Quote-Arg([string]$Value) {
    # Windows command-line quoting: wrap in double quotes, escape embedded double quotes as \".
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-Tts([string]$Text, [string]$Ref, [string]$RefText, [int]$UseSeed, [int]$UseMaxTokens, [string]$Out, [string]$Log) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    # Windows PowerShell 5.1 joins an ArgumentList array with spaces and does NOT quote elements,
    # so paths with spaces and the text itself would be split. Build one properly quoted command line.
    # Note: --text-chunk-size set to 9999 to disable CLI chunking when we do script-level chunking
    $parts = @(
        '--backend', $Backend, '--threads', $Threads,
        '--task', 'tts', '--family', 'higgs_audio_tts', '--model', (Quote-Arg $Model),
        '--text', (Quote-Arg $Text), '--voice-ref', (Quote-Arg $Ref), '--reference-text', (Quote-Arg $RefText),
        '--seed', $UseSeed, '--temperature', $Temperature.ToString($inv), '--top-k', $TopK, '--top-p', $TopP.ToString($inv),
        '--max-tokens', $UseMaxTokens, '--text-chunk-size', 9999, '--out', (Quote-Arg $Out)
    )
    if ($language) { $parts += @('--language', $language) }
    $p = Start-Process -FilePath $Cli -ArgumentList ($parts -join ' ') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    return $p.ExitCode
}

function Get-WavSeconds([string]$Path) {
    # Use ffprobe for accurate duration detection (format-agnostic).
    # Falls back to file size if ffprobe is not available.
    if (Get-Command ffprobe -ErrorAction SilentlyContinue) {
        $out = ffprobe -v error -show_entries format=duration -of csv=p=0 $Path 2>$null
        if ($out) { return [math]::Round([double]$out, 1) }
    }
    # Fallback: assume 24 kHz mono 16-bit PCM (48000 bytes per second, 44-byte header).
    return [math]::Round(((Get-Item $Path).Length - 44) / 48000.0, 1)
}

function Invoke-Ladder([string]$Text, [string]$Ref, [string]$RefText, [string]$Out, [string]$LogBase, [int]$UseMaxTokens = 0, [int]$MaxSeconds = 0) {
    if ($UseMaxTokens -le 0) { $UseMaxTokens = $MaxTokens }
    foreach ($off in $Ladder) {
        $s = $Seed + $off
        $log = "$LogBase-seed$s.log"
        $code = Invoke-Tts $Text $Ref $RefText $s $UseMaxTokens $Out $log
        if ($code -eq 0 -and (Test-Path $Out)) {
            if ($MaxSeconds -gt 0) {
                $secs = Get-WavSeconds $Out
                if ($secs -lt 2 -or $secs -gt $MaxSeconds) {
                    Write-Warning "seed $s produced ${secs}s for a ~5s sentence (babble), trying another seed"
                    Remove-Item $Out -Force
                    continue
                }
            }
            Write-Host "generated with seed $s"; return
        }
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
        # Same cap as the desktop app (1024 tokens) plus a length check: a good anchor is 3-8 s.
        Invoke-Ladder $AnchorText $voicePath $refText $anchor (Join-Path $Root "logs\anchor-$VoiceId-$stamp") 1024 12
    }
    $ref = $anchor
    $refTextUsed = $AnchorText
}

$out = Join-Path $Root "outputs\higgs-$stamp.wav"

# Sentence-aware chunking: generate each chunk with the same anchor, match levels, join with fixed gaps.
function Get-Lufs([string]$Path) {
    # ffmpeg prints its report on stderr; with ErrorActionPreference=Stop a captured stderr line
    # becomes a terminating NativeCommandError, so relax it while reading the measurement.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $txt = (& ffmpeg -nostats -i $Path -af ebur128 -f null - 2>&1 | Out-String)
    $ErrorActionPreference = $prev
    $m = [regex]::Matches($txt, ' I:\s+(-?[0-9.]+) LUFS')
    if ($m.Count -gt 0) { return [double]$m[$m.Count - 1].Groups[1].Value }
    return $null
}
$py = $null
foreach ($cand in 'python', 'python3', 'py') { $cmd = Get-Command $cand -ErrorAction SilentlyContinue; if ($cmd) { $py = $cmd.Source; break } }
$chunker = Join-Path $Root 'scripts\chunk_text.py'
$haveFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
if ($Chunking -eq 'smart' -and $py -and (Test-Path $chunker) -and $haveFfmpeg) {
    Write-Host "sentence-aware chunking (max $Chunk chars per chunk, ${GapMs} ms gap)"
    $work = Join-Path ([IO.Path]::GetTempPath()) ("higgs-chunks-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $inputFile = Join-Path $work 'input.txt'
    [IO.File]::WriteAllText($inputFile, $text, (New-Object Text.UTF8Encoding $false))
    $chunks = @(& $py $chunker $inputFile $Chunk 2>$null | Where-Object { $_ -and $_.Trim() })
    if ($chunks.Count -eq 0) { throw 'chunker returned no chunks' }
    $wavs = @(); $lufs = @()
    $i = 0
    foreach ($c in $chunks) {
        $i++
        $w = Join-Path $work ("chunk{0}.wav" -f $i)
        Invoke-Ladder $c $ref $refTextUsed $w (Join-Path $Root ("logs\generate-$stamp-chunk{0}" -f $i))
        $l = Get-Lufs $w
        $wavs += $w; $lufs += $l
        Write-Host ("  chunk {0}: {1} chars, {2} s, {3} LUFS" -f $i, $c.Length, (Get-WavSeconds $w), $l)
    }
    $valid = @($lufs | Where-Object { $_ -ne $null } | Sort-Object)
    $median = if ($valid.Count -gt 0) { $valid[[int][math]::Floor(($valid.Count - 1) / 2)] } else { $null }
    if ($median -ne $null) { Write-Host ("  level target (median): {0} LUFS" -f $median) }
    $gap = Join-Path $work 'gap.wav'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ErrorActionPreference = 'Continue'
    & ffmpeg -y -hide_banner -loglevel error -f lavfi -i 'anullsrc=r=24000:cl=mono' -t ($GapMs / 1000.0).ToString($inv) -c:a pcm_s16le $gap
    $concat = Join-Path $work 'concat.txt'
    $lines = @()
    for ($k = 0; $k -lt $wavs.Count; $k++) {
        $gain = 0.0
        if ($median -ne $null -and $lufs[$k] -ne $null) { $gain = [math]::Round([math]::Max(-6.0, [math]::Min(6.0, $median - $lufs[$k])), 2) }
        $lv = Join-Path $work ("level{0}.wav" -f ($k + 1))
        $af = "volume=" + $gain.ToString($inv) + "dB,alimiter=limit=0.95:attack=5:release=50,afade=t=in:d=0.005,areverse,afade=t=in:d=0.005,areverse"
        & ffmpeg -y -hide_banner -loglevel error -i $wavs[$k] -af $af -ac 1 -ar 24000 -c:a pcm_s16le $lv
        Write-Host ("  chunk {0}: gain {1} dB -> {2} LUFS" -f ($k + 1), $gain, (Get-Lufs $lv))
        $lines += "file '" + ($lv -replace "'", "'\''") + "'"
        if ($k -lt $wavs.Count - 1) { $lines += "file '" + ($gap -replace "'", "'\''") + "'" }
    }
    [IO.File]::WriteAllLines($concat, $lines, (New-Object Text.UTF8Encoding $false))
    & ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i $concat -af 'apad=pad_dur=0.15' -ac 1 -ar 24000 -c:a pcm_s16le $out
    $ErrorActionPreference = 'Stop'
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Write-Host ("joined {0} chunks -> {1}" -f $wavs.Count, $out)
} else {
    if ($Chunking -eq 'smart') { Write-Warning 'python/ffmpeg or scripts\chunk_text.py not available: using the CLI chunker' }
    Invoke-Ladder $text $ref $refTextUsed $out (Join-Path $Root "logs\generate-$stamp")
    if ($haveFfmpeg) {
        $padded = "$out.pad.wav"
        & ffmpeg -y -hide_banner -loglevel error -i $out -af 'apad=pad_dur=0.15' -ac 1 -ar 24000 -c:a pcm_s16le $padded
        if (Test-Path $padded) { Move-Item -Force $padded $out }
    }
    Write-Host $out
}
