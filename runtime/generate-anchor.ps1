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

# Check for sentence-aware chunking
if ($Chunking -eq 'smart') {
    $chunker = Join-Path $Root 'scripts\chunk_text.py'
    if ((Get-Command python3 -ErrorAction SilentlyContinue) -and (Test-Path $chunker)) {
        Write-Host "Chunking text with sentence-aware splitter (chunk size: $Chunk, gap: ${GapMs}ms)"
        $tmpDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "higgs-chunks-$([System.Diagnostics.Process]::GetCurrentProcess().Id)")
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

        # Write text to temp file for chunker
        $textFile = Join-Path $tmpDir 'input.txt'
        [IO.File]::WriteAllText($textFile, $text, [Text.Encoding]::UTF8)

        # Get chunks
        try {
            $chunks = @(python3 $chunker $textFile $Chunk | Where-Object { $_ })
        } catch {
            Write-Warning "Failed to chunk text, falling back to single-call mode: $_"
            $chunks = $null
        }

        if ($chunks) {
            Write-Host "Generated $($chunks.Count) chunks, measuring loudness and generating audio..."

            $chunkFiles = @()
            $chunkInfo = @()

            for ($idx = 0; $idx -lt $chunks.Count; $idx++) {
                $chunkText = $chunks[$idx]
                $chunkWav = Join-Path $tmpDir "chunk_$idx.wav"
                $logBase = Join-Path $Root "logs\generate-$stamp-chunk$idx"

                # Generate chunk
                try {
                    Invoke-Ladder $chunkText $ref $refTextUsed $chunkWav $logBase | Out-Null
                    $chunkFiles += $chunkWav

                    # Measure loudness (ffprobe if available)
                    try {
                        $sec = Get-WavSeconds $chunkWav
                        Write-Host "  chunk $idx`: $($chunkText.Length) chars, ${sec}s"
                    } catch {
                        Write-Host "  chunk $idx`: $($chunkText.Length) chars"
                    }
                } catch {
                    Write-Host "Failed to generate chunk $idx`:" $_.Exception.Message
                    throw
                }
            }

            # For now, simple concatenation with ffmpeg
            # (Full level-matching logic deferred to future implementation on Windows)
            Write-Host "Joining $($chunkFiles.Count) chunks..."

            # Use ffmpeg concat demuxer
            $concatFile = Join-Path $tmpDir 'concat.txt'
            [IO.File]::WriteAllText($concatFile, @(
                $chunkFiles | ForEach-Object { "file '$_'" }
            ) -join "`r`n", [Text.Encoding]::UTF8)

            $args = @(
                '-y', '-hide_banner', '-loglevel', 'error',
                '-f', 'concat', '-safe', '0', '-i', $concatFile,
                '-c:a', 'pcm_s16le',
                $out
            )
            & ffmpeg $args

            Remove-Item -Recurse -Force $tmpDir
            Write-Host $out
        } else {
            # Fallback to single-call mode
            Write-Host "Python3 or chunker not found, falling back to single-call mode"
            Invoke-Ladder $text $ref $refTextUsed $out (Join-Path $Root "logs\generate-$stamp")
            Write-Host $out
        }
    } else {
        # Fallback to single-call mode
        Write-Host "Python3 or chunker not found, falling back to single-call mode"
        Invoke-Ladder $text $ref $refTextUsed $out (Join-Path $Root "logs\generate-$stamp")
        Write-Host $out
    }
} else {
    # Original single-call mode (Chunking=cli)
    Write-Host "Using CLI chunking (--text-chunk-size $Chunk)"
    Invoke-Ladder $text $ref $refTextUsed $out (Join-Path $Root "logs\generate-$stamp")
    Write-Host $out
}
