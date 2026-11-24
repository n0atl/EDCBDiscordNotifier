[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$PSDefaultParameterValues['ConvertTo-Json:Encoding'] = 'utf8'
$IsFromEDCB = $env:ServiceName -or $env:Title -or $env:FilePath

# =========================
# ターゲット定義 (targets.psd1)
# =========================
# targets.psd1 があれば、その定義にしたがって複数の送信先 (Discord サーバー) へ通知する。
# 無ければ自フォルダの config.psd1 のみを使う単一ターゲットとして動作する (従来どおり)。
# 各ターゲット: Name (ログ表示名) / ConfigDir (config.psd1 のあるフォルダ。この ps1 からの相対でも絶対でも可) / Modes (担当モード。省略時は全モード)
$EngineRoot = $PSScriptRoot
$NotifierTargets = @(
    @{ Name = ''; ConfigPath = (Join-Path $EngineRoot 'config.psd1'); Modes = $null }
)
$targetsFile = Join-Path $EngineRoot 'targets.psd1'
if (Test-Path -LiteralPath $targetsFile) {
    try {
        $targetsData = Import-PowerShellDataFile -LiteralPath $targetsFile
        if ($targetsData.Targets) {
            $NotifierTargets = @(
                foreach ($t in $targetsData.Targets) {
                    $dir = [string]$t.ConfigDir
                    if (-not $dir -or $dir -eq '.') { $dir = $EngineRoot }
                    elseif (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $EngineRoot $dir }
                    @{ Name = [string]$t.Name; ConfigPath = (Join-Path $dir 'config.psd1'); Modes = $t.Modes }
                }
            )
        }
    } catch {
        Write-Error "targets.psd1 の読み込みに失敗しました: $($_.Exception.Message)"
    }
}
# =========================
# 共通関数
# =========================
# 局ロゴ追加 26.02.14
# 局ロゴ追加 26.06.27 JSON外部参照方式に変更
# 局ロゴ判定 26.11.14 ONID-SID のキーと、局名の最長一致に対応
# =========================
# DTVlogo.json の書き方は README の「局ロゴ絵文字」を参照
#   局名は 全角/半角、大文字/小文字、空白の数、ダッシュ・波ダッシュの種類 の違いを無視して比較する
#   判定の優先順位: 1. "ONID-SID" のキー  2. 局名のキー (一番長く一致したもの。その中で "sid" に今の SID があればそれを使う)

function ConvertTo-DTVLogoKey {
    # 比較用に正規化 (NFKC で全角英数→半角、連続する空白は1つに)
    # 空白を消すと「TBS NEWS」が「BSN」に一致するなど誤判定が出るので、空白は残す
    # ダッシュ類 (－ − ‐ など) と 波ダッシュ類 (～ 〜) は、コピーや文字コード変換で入れ替わりやすいので同じ文字として扱う
    param([string]$Text)
    if (-not $Text) { return "" }
    $t = $Text.Normalize([Text.NormalizationForm]::FormKC)
    $t = $t -replace '[‐-―−﹣－]', '-' -replace '[〜～∼]', '~'
    return ($t -replace '\s+', ' ').Trim()
}

function Test-DTVLogoIdKey {
    # "ONID-SID" の形のキーか
    param([string]$Key)
    return ($Key -match '^\d+-\d+$')
}

function New-DTVLogoValue {
    # 値 (絵文字と、SID ごとの例外) を作る
    param([string]$Emoji = "", $Sid = $null)
    $v = @{ emoji = $Emoji; sid = [ordered]@{} }
    if ($Sid) { foreach ($k in $Sid.Keys) { $v.sid["$k"] = [string]$Sid[$k] } }
    return $v
}

function Import-DTVLogoMap {
    # DTVlogo.json を読み込み、順序付きハッシュテーブル (キー → @{ emoji; sid }) で返す
    param([string]$Path)
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($p in $json.psobject.Properties) {
        $val = $p.Value
        if ($val -is [string] -or $null -eq $val) {
            $map[$p.Name] = New-DTVLogoValue -Emoji ([string]$val)
        } else {
            $sid = [ordered]@{}
            if ($val.sid) { foreach ($s in $val.sid.psobject.Properties) { $sid[$s.Name] = [string]$s.Value } }
            $map[$p.Name] = New-DTVLogoValue -Emoji ([string]$val.emoji) -Sid $sid
        }
    }
    return $map
}

function Find-DTVLogo {
    # 一番条件に合うキーを返す。無ければ $null
    # 戻り値: @{ Key; Emoji; Kind ("id" / "name" / "name+sid") }
    param(
        $Map,
        [string]$Onid,
        [string]$Sid,
        [string]$ServiceName
    )
    [int]$onidInt = -1
    [int]$sidInt = -1
    $hasOnid = [int]::TryParse($Onid, [ref]$onidInt)
    $hasSid = [int]::TryParse($Sid, [ref]$sidInt)

    if ($hasOnid -and $hasSid -and $Map.Contains("$onidInt-$sidInt")) {
        return @{ Key = "$onidInt-$sidInt"; Emoji = $Map["$onidInt-$sidInt"].emoji; Kind = "id" }
    }

    $nameKey = ConvertTo-DTVLogoKey $ServiceName
    if (-not $nameKey) { return $null }
    $best = $null
    $bestLen = 0
    foreach ($k in $Map.Keys) {
        if (Test-DTVLogoIdKey $k) { continue }
        $mk = ConvertTo-DTVLogoKey $k
        if ($mk -and $mk.Length -gt $bestLen -and $nameKey.IndexOf($mk, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $best = $k
            $bestLen = $mk.Length
        }
    }
    if ($null -eq $best) { return $null }
    $v = $Map[$best]
    if ($hasSid -and $v.sid.Contains("$sidInt")) {
        return @{ Key = $best; Emoji = $v.sid["$sidInt"]; Kind = "name+sid" }
    }
    return @{ Key = $best; Emoji = $v.emoji; Kind = "name" }
}

function Get-ServiceEmoji {
    param([string]$ServiceName, [string]$Onid, [string]$Sid)
    $jsonPath = Join-Path $PSScriptRoot "DTVlogo.json"
    try {
        $map = Import-DTVLogoMap -Path $jsonPath
        $hit = Find-DTVLogo -Map $map -Onid $Onid -Sid $Sid -ServiceName $ServiceName
        if ($hit) {
            Debug-Print "Logo      : $($hit.Key) ($($hit.Kind))"
            return $hit.Emoji
        }
    } catch {
        Debug-Print "Logo      : DTVlogo.json の読み込みに失敗 $($_.Exception.Message)"
    }
    return ""
}
# =========================

function Get-DriveSpaceText {
    param($Path)
	# 表示設定が false なら何も返さない
    if (-not $ENABLE_DRIVE_INFO) { return "" }
    
    if (-not $Path) { return "" }
	
    try {
        $driveLetter = Split-Path -Path $Path -Qualifier
        if (-not $driveLetter) { return "" }

        $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetter'"
        if ($drive) {
            $freeByte = $drive.FreeSpace
            
            # 単位の自動繰り上げ（TBまで対応）
            if ($freeByte -ge 1TB) {
                $freeText = "{0:N2}TB" -f ($freeByte / 1TB)
            } elseif ($freeByte -ge 1GB) {
                $freeText = "{0:N2}GB" -f ($freeByte / 1GB)
            } elseif ($freeByte -ge 1MB) {
                $freeText = "{0:N2}MB" -f ($freeByte / 1MB)
            } else {
                $freeText = "{0:N2}KB" -f ($freeByte / 1KB)
            }

            # ▼ 設定に基づいて警告絵文字を判定
            $alert = ""
            if ($ENABLE_DRIVE_ALERT -and ($freeByte -lt $DRIVE_ALERT_THRESHOLD)) {
                $alert = "⚠️"
            }

            $driveName = $driveLetter.TrimEnd(":")
            return " $driveName-Free:$alert**$freeText**"
        }
    } catch {
        return ""
    }
    return ""
}

function Test-DenyByKeyword {
    param(
        [string]$Target,
        [string[]]$Keywords
    )

    if (-not $Target) { return $false }
    # 空文字・空白だけのキーワードは無視 ("**" が全てに一致してしまうため)
    $Keywords = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Keywords.Count -eq 0) {
        return $false   # 未指定＝拒否しない
    }

    foreach ($k in $Keywords) {
        if ($Target -like "*$k*") {
            return $true
        }
    }
    return $false
}

function Test-AllowByKeyword {
    param(
        [string]$Target,
        [string[]]$Keywords
    )

    if (-not $Target) { return $true }
    # 空文字・空白だけのキーワードは無視
    $Keywords = @($Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Keywords.Count -eq 0) {
        return $true    # 未指定＝全許可
    }

    foreach ($k in $Keywords) {
        if ($Target -like "*$k*") {
            return $true
        }
    }
    return $false
}

function Get-Env {
    param($Name, $Default = "-")

    $value = (Get-Item -Path "env:$Name" -ErrorAction SilentlyContinue).Value
    if ($null -ne $value -and $value -ne "") {
        return $value
    }
    return $Default
}

function Escape-DiscordMarkdown {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $chars = '\','*','_','~','`','>','|'
    foreach ($c in $chars) {
        $Text = $Text -replace [regex]::Escape($c), "\$c"
    }
    # 行頭の # (見出し) と - (箇条書き・小さい文字) も文字として表示させる 26.11.14
    $Text = $Text -replace '(?m)^(\s*)([#-])', '$1\$2'
    return $Text
}

function Get-FileSizeEx {
    param($Path)

    if (-not $Path) {
        return @{ Status="NO_PATH"; SizeText="-" }
    }

    $Path = $Path.Trim('"')

    for ($i = 0; $i -lt 6; $i++) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $item = Get-Item -LiteralPath $Path
                $size = $item.Length

                if ($size -eq 0) {
                    # 0byteでも確定したら異常扱い
                    return @{ Status="ZERO"; SizeText="0B" }
                }

                if ($size -gt 0) {
                    if ($size -lt 1KB) { $t = "${size}B" }
                    elseif ($size -lt 1MB) { $t = "{0:N2}KB" -f ($size/1KB) }
                    elseif ($size -lt 1GB) { $t = "{0:N2}MB" -f ($size/1MB) }
                    else { $t = "{0:N2}GB" -f ($size/1GB) }

                    return @{ Status="OK"; SizeText=$t }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 500
    }

    return @{ Status="UNKNOWN"; SizeText="-" }
}


function Parse-DateTime {
    param($Y,$M,$D,$H,$Min)
    try {
        return Get-Date ("{0}/{1}/{2} {3}:{4}" -f $Y,$M,$D,$H,$Min)
    } catch {
        return $null
    }
}


# =========================
# 録画終了時番組内容追加 26.02.15
# 録画終了時番組内容追加 26.02.15
function Get-ProgramSummary {
    param(
        [string]$TsPath
    )

    if (-not $TsPath) { return "" }

    # .ts → .ts.program.txt
    $programPath = "$TsPath.program.txt"

    if (-not (Test-Path -LiteralPath $programPath)) {
        return ""   # 無ければ何も返さない（エラーにしない）
    }

    try {
        $lines = Get-Content -LiteralPath $programPath -Encoding Default
    } catch {
        return ""
    }

    $collect = $false
    $summary = @()

    foreach ($line in $lines) {

        if (-not $collect) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                $collect = $true
            }
            continue
        }

		if ($line -match "^詳細情報\s*$" `
			-or $line -match "^ジャンル\s*[:：]" `
			-or $line -match "^映像\s*[:：]" ) {
			break
		}

        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $summary += $line
        }
    }

    return ($summary -join "`n").Trim()
}
# =========================

# 録画失敗時にメンション 26.06.28
function Test-NeedAlertMention {
    param(
        [int]$DropCount,
        [string]$Result,
        [string]$FileStatus
    )

    # Drop
    if ($ENABLE_DROP_MENTION -and $DropCount -gt 0) {
        return $true
    }

    # 0Byte
    if ($ENABLE_ERROR_MENTION -and $FileStatus -eq "ZERO") {
        return $true
    }

    # EDCBエラー
    if ($ENABLE_ERROR_MENTION) {

        $errorResults = @(
            "録画開始処理に失敗しました",
            "チューナーのオープンに失敗しました",
            "ファイル保存で致命的なエラーが発生した可能性があります"
        )

        if ($errorResults -contains $Result) {
            return $true
        }
    }

    return $false
}

# =========================
# デバッグ出力関数
# =========================
function Debug-Print {
    param([string]$Text)
    
    # $DEBUG が未定義の場合は $true（デバッグ有効）として扱う
    $isDebug = if ($null -ne $DEBUG) { $DEBUG } else { $true }
    
    if ($isDebug) {
        $prefix = ""
        if ($script:TargetName) { $prefix = "[$script:TargetName] " }
        Write-Host "$prefix$Text" -ForegroundColor DarkGray
    }
}
# =========================
# メイン
# =========================

function New-RecThumbnail {
    # 録画TSから等間隔サンプリングのタイル画像を生成し、一時ファイルのパスを返す。失敗時は $null
    # ffmpeg 1回の実行で完結する (中間の個別フレーム画像は作らない)
    param([string]$TsPath)
    if (-not $ENABLE_REC_THUMBNAIL) { return $null }
    if (-not $TsPath -or -not (Test-Path -LiteralPath $TsPath)) { return $null }
    if (-not (Test-Path -LiteralPath $FFMPEG_PATH)) {
        Debug-Print "⚠️ サムネイル: ffmpeg が見つかりません ($FFMPEG_PATH)"
        return $null
    }
    $tmp = Join-Path $env:TEMP ("edcb_thumb_{0}.jpg" -f [guid]::NewGuid().ToString('N'))
    try {
        # 総再生時間を取得
        $durLine = (& $FFMPEG_PATH -hide_banner -i $TsPath 2>&1 | Select-String 'Duration: ' | Select-Object -First 1).Line
        $m = [regex]::Match([string]$durLine, 'Duration: (\d+):(\d+):([\d.]+)')
        if (-not $m.Success) {
            Debug-Print "⚠️ サムネイル: Duration を取得できませんでした"
            return $null
        }
        $total = [int]$m.Groups[1].Value * 3600 + [int]$m.Groups[2].Value * 60 + [double]$m.Groups[3].Value
        if ($total -le 0) { return $null }

        # 録画時間に合わせてグリッドを変える (短い録画でサムネが密になりすぎないように)。上限は config の THUMB_COLS/ROWS
        $gridMax = [math]::Min($THUMB_COLS, $THUMB_ROWS)
        $grid = 6
        if ($total -lt 180) { $grid = 2 }
        elseif ($total -lt 480) { $grid = 3 }
        elseif ($total -lt 900) { $grid = 4 }
        elseif ($total -lt 1500) { $grid = 5 }
        if ($grid -gt $gridMax) { $grid = $gridMax }
        Debug-Print "🖼️ サムネイル: $([int]$total)秒 → ${grid}x${grid}"
        $n = $grid * $grid
        # マスが少ない時は1マスを大きくする (2x2: 640x360 / 3x3: 512x288 / それ以外: 384x216)
        $w = 384
        if ($grid -le 2) { $w = 640 } elseif ($grid -eq 3) { $w = 512 }
        $h = [int]($w * 9 / 16)
        $fontSize = [math]::Max(14, [int]($h * 0.075))
        $ffArgs = @('-y', '-v', 'error')
        $scales = @(); $layout = @(); $ins = @()
        for ($i = 0; $i -lt $n; $i++) {
            $t = [math]::Round(($i + 0.5) * $total / $n, 2)
            $ffArgs += @('-ss', "$t", '-i', $TsPath)
            # 各マスの左下に、そのフレームの再生時間を表示する
            $tsSpan = [TimeSpan]::FromSeconds($t)
            if ($total -ge 3600) { $tsText = $tsSpan.ToString('h\:mm\:ss') } else { $tsText = $tsSpan.ToString('mm\:ss') }
            $tsEsc = $tsText -replace ':', '\:'
            $scales += "[$i`:v]yadif,scale=$w`:$h,setsar=1,drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='$tsEsc':x=6:y=h-text_h-6:fontsize=${fontSize}:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=5[s$i]"
            $layout += ("{0}_{1}" -f (($i % $grid) * $w), ([math]::Floor($i / $grid) * $h))
            $ins += "[s$i]"
        }
        $fc = ($scales -join ';') + ';' + ($ins -join '') + "xstack=inputs=$n`:layout=" + ($layout -join '|') + '[out]'
        $ffArgs += @('-filter_complex', $fc, '-map', '[out]', '-frames:v', '1', '-q:v', '3', $tmp)

        # 60秒でタイムアウト (通知全体を止めないため)
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FFMPEG_PATH
        $psi.Arguments = ($ffArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $proc = [Diagnostics.Process]::Start($psi)
        # stderr は非同期で読み捨てる (溜めるとパイプが詰まって ffmpeg が止まる)
        $errRead = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(60000)) {
            try { $proc.Kill() } catch {}
            Debug-Print "⚠️ サムネイル: ffmpeg がタイムアウトしました"
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $null
        }
        try { $errRead.Wait(3000) | Out-Null } catch {}
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -le 0) {
            Debug-Print "⚠️ サムネイル: ffmpeg の生成に失敗しました (ExitCode: $($proc.ExitCode))"
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $null
        }
        Debug-Print "🖼️ サムネイル生成: $tmp"
        return $tmp
    } catch {
        Debug-Print "⚠️ サムネイル生成で例外: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $null
    }
}

# 26.11.14 中身のない URL (config.psd1 の初期値 "https://discord.com/api/webhooks/" など) は未設定として扱う
function Test-WebhookUrl {
    param([string]$Url)
    return ($Url -match '^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/\d+/[\w-]+')
}

# 26.11.14 送信に失敗したら再送する
#   429 (送信制限)         … Discord が指定する秒数だけ待って再送
#   5xx / 通信エラー        … 少しずつ間隔をあけて再送
#   それ以外 (400 など)     … 何度送っても同じなので再送しない
function Send-DiscordWebhook {
    param([string]$Url, [string]$Body, [int]$MaxTry = 5)
    $backoff = @(2, 5, 10, 20)
    for ($try = 1; $try -le $MaxTry; $try++) {
        try {
            Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' -Body $Body | Out-Null
            if ($try -gt 1) { Debug-Print "✅ 再送で送信できました ($try 回目)" }
            return $true
        } catch {
            $status = 0
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch {} }
            $detail = $_.ErrorDetails.Message
            # PowerShell 5.1 ではエラー応答の本文が入らないことがあるので、直接読む
            if (-not $detail -and $_.Exception.Response) {
                try {
                    $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                    $detail = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch {}
            }
            if (-not $detail) { $detail = $_.Exception.Message }

            if ($status -eq 429) {
                $wait = 0
                try { $wait = [double]($detail | ConvertFrom-Json).retry_after } catch {}
                if ($wait -le 0) { try { $wait = [double]$_.Exception.Response.Headers["Retry-After"] } catch {} }
                if ($wait -le 0) { $wait = 5 }
                $wait = [math]::Min([math]::Ceiling($wait) + 1, 60)
            } elseif ($status -eq 0 -or $status -ge 500) {
                $wait = $backoff[[math]::Min($try - 1, $backoff.Count - 1)]
            } else {
                Debug-Print "❌ 送信に失敗しました ($status): $detail"
                return $false
            }

            if ($try -ge $MaxTry) {
                Debug-Print "❌ $MaxTry 回送っても失敗しました ($status): $detail"
                return $false
            }
            Debug-Print "…送信に失敗しました ($status)。$wait 秒後に再送します ($try/$MaxTry)"
            Start-Sleep -Seconds $wait
        }
    }
    return $false
}

function Send-DiscordWebhookWithFile {
    # 画像ファイルを添付して送信する (multipart/form-data)。再送ルールは Send-DiscordWebhook と同じ
    param([string]$Url, [string]$Body, [string]$FilePath, [string]$AttachName = 'thumbnail.jpg', [int]$MaxTry = 5)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $backoff = @(2, 5, 10, 20)
    for ($try = 1; $try -le $MaxTry; $try++) {
        $client = [System.Net.Http.HttpClient]::new()
        $content = [System.Net.Http.MultipartFormDataContent]::new()
        try {
            $jsonPart = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
            $content.Add($jsonPart, 'payload_json')
            $filePart = [System.Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($FilePath))
            $filePart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/jpeg')
            $content.Add($filePart, 'files[0]', $AttachName)
            $resp = $client.PostAsync($Url, $content).Result
            $status = [int]$resp.StatusCode
            if ($resp.IsSuccessStatusCode) {
                if ($try -gt 1) { Debug-Print "✅ 再送で送信できました ($try 回目)" }
                return $true
            }
            $detail = $resp.Content.ReadAsStringAsync().Result
            if ($status -eq 429) {
                $wait = 0
                try { $wait = [double]($detail | ConvertFrom-Json).retry_after } catch {}
                if ($wait -le 0) { $wait = 5 }
                $wait = [math]::Min([math]::Ceiling($wait) + 1, 60)
            } elseif ($status -ge 500) {
                $wait = $backoff[[math]::Min($try - 1, $backoff.Count - 1)]
            } else {
                Debug-Print "❌ 送信に失敗しました ($status): $detail"
                return $false
            }
            if ($try -ge $MaxTry) {
                Debug-Print "❌ $MaxTry 回送っても失敗しました ($status): $detail"
                return $false
            }
            Debug-Print "…送信に失敗しました ($status)。$wait 秒後に再送します ($try/$MaxTry)"
            Start-Sleep -Seconds $wait
        } catch {
            if ($try -ge $MaxTry) {
                Debug-Print "❌ $MaxTry 回送っても失敗しました: $($_.Exception.Message)"
                return $false
            }
            $wait = $backoff[[math]::Min($try - 1, $backoff.Count - 1)]
            Debug-Print "…送信に失敗しました。$wait 秒後に再送します ($try/$MaxTry)"
            Start-Sleep -Seconds $wait
        } finally {
            $content.Dispose()
            $client.Dispose()
        }
    }
    return $false
}

# =========================
# ターゲット1件分の処理 (config 読み込み → フィルタ → メッセージ生成 → 送信)
# 戻り値: 'ok' (送信した) / 'skip' (フィルタや条件で送信しなかった) / 'fail' (送信に失敗した)
# =========================
function Invoke-NotifierTarget {
    param([string]$ConfigPath, [string]$SharedThumbPath)
# =========================
# 設定読み込み (このターゲットの config.psd1)
# =========================
$configPath = $ConfigPath
if (-not (Test-Path -LiteralPath $configPath)) {
    Debug-Print "❌ config.psd1が見つかりません: $configPath"
    return 'fail'
}
# 安全にPSD1ファイルを読み込んでハッシュテーブルとして格納
$Config = Import-PowerShellDataFile -LiteralPath $configPath

# 各変数へ展開
$DISCORD_WEBHOOK_URL    = $Config.DISCORD_WEBHOOK_URL
$WEBHOOK_ADD_RESERVE    = $Config.WEBHOOK_ADD_RESERVE
$WEBHOOK_CHG_RESERVE    = $Config.WEBHOOK_CHG_RESERVE
$WEBHOOK_REC_START      = $Config.WEBHOOK_REC_START
$WEBHOOK_REC_END        = $Config.WEBHOOK_REC_END
$DISCORD_USERNAME       = $Config.DISCORD_USERNAME
$DISCORD_AVATAR         = $Config.DISCORD_AVATAR
$ENABLE_DRIVE_INFO      = $Config.ENABLE_DRIVE_INFO
$ENABLE_DRIVE_ALERT     = $Config.ENABLE_DRIVE_ALERT
$ENABLE_DROP_MENTION  = $Config.ENABLE_DROP_MENTION
$ENABLE_ERROR_MENTION = $Config.ENABLE_ERROR_MENTION
# 録画終了サムネイル (config.psd1 未設定なら既定値を使う)
$ENABLE_REC_THUMBNAIL = $Config.ENABLE_REC_THUMBNAIL
if ($null -eq $ENABLE_REC_THUMBNAIL) { $ENABLE_REC_THUMBNAIL = $true }
$FFMPEG_PATH = $Config.FFMPEG_PATH
if (-not $FFMPEG_PATH) { $FFMPEG_PATH = 'C:\ffmpeg\ffmpeg.exe' }
$THUMB_COLS = $Config.THUMB_COLS
if (-not $THUMB_COLS) { $THUMB_COLS = 6 }
$THUMB_ROWS = $Config.THUMB_ROWS
if (-not $THUMB_ROWS) { $THUMB_ROWS = 6 }
# メンション先 (config.psd1 の MENTION_ID。旧名 ALERT_MENTION にも対応)
$ALERT_MENTION        = $Config.MENTION_ID
if (-not $ALERT_MENTION) { $ALERT_MENTION = $Config.ALERT_MENTION }
# 未記入のサンプル値 "<@>" などはメンション無しとして扱う
if ($ALERT_MENTION -match '^\s*<@[!&]?>\s*$') { $ALERT_MENTION = "" }

# PSD1側で「100GB」と書いたデータがそのまま実バイト数として入ります
$DRIVE_ALERT_THRESHOLD  = $Config.DRIVE_ALERT_THRESHOLD

# 配列オブジェクトの変換（明示的に型を固定）
$ALLOW_SERVICES         = [string[]]$Config.ALLOW_SERVICES
$ALLOW_TITLES           = [string[]]$Config.ALLOW_TITLES
$DENY_SERVICES          = [string[]]$Config.DENY_SERVICES
$DENY_TITLES            = [string[]]$Config.DENY_TITLES

# =========================


# =========================
# 局ロゴ追加 26.02.14
$serviceRaw = Get-Env "ServiceName"
$discord_emoji = Get-ServiceEmoji $serviceRaw (Get-Env ONID10) (Get-Env SID10)
# =========================


$title      = Escape-DiscordMarkdown (Get-Env "Title")
$title_old  = Escape-DiscordMarkdown (Get-Env "TitleOLD")
# $service    = Escape-DiscordMarkdown (Get-Env "ServiceName")
$service    = Escape-DiscordMarkdown $serviceRaw
$ONID		= Get-Env ONID10
$startDate  = "{0}/{1}/{2}" -f (Get-Env SDYYYY),(Get-Env SDMM),(Get-Env SDDD)
$startTime  = "{0}:{1}" -f (Get-Env STHH),(Get-Env STMM)
$endTime    = "{0}:{1}" -f (Get-Env ETHH),(Get-Env ETMM)
$SDW        = Get-Env SDW
$SDWOLD     = Get-Env SDWOLD

$result     = Get-Env Result
$drops      = Get-Env Drops
$scrambles  = Get-Env Scrambles
$filePath  = Get-Env FilePath
$recComment = Get-Env ReserveComment
$EID = Get-Env EID10

Debug-Print "=============================="
Debug-Print "EDCB Notifier Debug"
Debug-Print "Mode      : $mode"
Debug-Print "Service   : $service"
Debug-Print "Title     : $title"
Debug-Print "Datetime     : $startDate($SDW) $startTime ~ $endTime"
Debug-Print "Result    : $result"
Debug-Print "FilePath  : $filePath"
Debug-Print "=============================="

# 実行可否判定
if ($IsFromEDCB) {

    # --- DENY
    if (Test-DenyByKeyword $service $DENY_SERVICES) {
        Debug-Print "❌ DENY: 指定した放送局により除外されました"
        return 'skip'
    }
    if (Test-DenyByKeyword $title $DENY_TITLES) {
        Debug-Print "❌ DENY: 指定した番組名により除外されました"
        return 'skip'
    }
    # --- ALLOW
    if (-not (Test-AllowByKeyword $service $ALLOW_SERVICES)) {
        Debug-Print "❌ ALLOW: Service が許可リストに含まれていません"
        return 'skip'
    }

    if (-not (Test-AllowByKeyword $title $ALLOW_TITLES)) {
        Debug-Print "❌ ALLOW: Title が許可リストに含まれていません"
        return 'skip'
    }

    Debug-Print "✅フィルタ通過"
}
else {
    Debug-Print "🛠️EDCB以外からの実行"
}


# ネットワーク名判定
$NWN = ""
[int]$onidInt = 0
if ([int]::TryParse($ONID, [ref]$onidInt)) {

    if ($ONID -eq "--") {
        $NWN = ""
    }
    elseif ($onidInt -ge 0x7880 -and $onidInt -le 0x7FE8) {
        $NWN = "(地デジ)"
    }
    elseif ($onidInt -eq 0x0004) {
        $NWN = "(BS)"
    }
    elseif ($onidInt -eq 0x0006) {
        $NWN = "(CS1)"
    }
    elseif ($onidInt -eq 0x0007) {
        $NWN = "(CS2)"
    }
    elseif ($onidInt -eq 0x000B) {
        $NWN = "(高度BS)"
    }
    elseif ($onidInt -eq 0x000C) {
        $NWN = "(高度CS)"
    }
    elseif ($onidInt -in @(0xFFFE, 0xFFFA, 0xFFFD, 0xFFF9)) {
        $NWN = "(CATV)"
    }
    elseif ($onidInt -eq 0x000A) {
        $NWN = "(SKY)"
    }
    elseif ($onidInt -eq 0x0001) {
        $NWN = "(STARDIGIO)"
    }
}


# Dropsアイコン判定
$dropsIcon = "⏹️"
[int]$dropCount = -1
[int]::TryParse($drops, [ref]$dropCount) | Out-Null

$normalResults = @(
    "録画終了",
    "終了",
    "録画中にキャンセルされた可能性があります",
    "次の予約開始のためにキャンセルされました",
    "録画終了（空き容量不足で別フォルダへの保存が発生）",
	"開始時間が変更されました"
)

if ($dropCount -gt 0 -or ($dropCount -eq 0 -and ($normalResults -notcontains $result))) {
	$dropsIcon = "⚠️"
	# $dropsIcon = "<a:emergency:1400848075341303818>"
}


# =========================
# プログラム予約か判別 26.02.15

$recCommentText = ""

if ($EID -eq "65535") {
    $recCommentText = " (プログラム予約)"
}
elseif ($recComment -like "*EPG自動予約*") {
    $recCommentText = " $recComment"
}
# =========================


# =========================
# モード別メッセージ生成
# =========================

$message = ""

switch ($mode) {
    
    # 予約追加
    "PostAddReserve" {
        $message = $ExecutionContext.InvokeCommand.ExpandString($Config.ADD_RESERVE)
    }

    # 予約変更(3種類)
    "PostChgReserve" {
        $startOld = Parse-DateTime (Get-Env SDYYYYOLD) (Get-Env SDMMOLD) (Get-Env SDDDOLD) (Get-Env STHHOLD) (Get-Env STMMOLD)
        $endOld   = Parse-DateTime (Get-Env EDYYYYOLD) (Get-Env EDMMOLD) (Get-Env EDDDOLD) (Get-Env ETHHOLD) (Get-Env ETMMOLD)
        $startNew = Parse-DateTime (Get-Env SDYYYY) (Get-Env SDMM) (Get-Env SDDD) (Get-Env STHH) (Get-Env STMM)
        $endNew   = Parse-DateTime (Get-Env EDYYYY) (Get-Env EDMM) (Get-Env EDDD) (Get-Env ETHH) (Get-Env ETMM)
        $titleChanged = $title_old -ne $title
        $timeChanged  = ($startOld -ne $startNew -or $endOld -ne $endNew)

        # 番組名と日時が一致してたら実行しない
        if (-not ($titleChanged -or $timeChanged)) { return 'skip' }

        # テンプレート用に時間表記を共通変数化
        $timeOldText = $startOld.ToString("yy/MM/dd($SDWOLD) HH:mm") + "～" + $endOld.ToString("HH:mm")
        $timeNewText = $startNew.ToString("yy/MM/dd($SDW) HH:mm") + "～" + $endNew.ToString("HH:mm")

        # 予約変更(番組名変更)
        if ($titleChanged -and -not $timeChanged) {
            $message = $ExecutionContext.InvokeCommand.ExpandString($Config.TEMPLATE_CHG_TITLE)
        }
        # 予約変更(放送時間変更)
        elseif ($timeChanged -and -not $titleChanged) {
            $message = $ExecutionContext.InvokeCommand.ExpandString($Config.TEMPLATE_CHG_TIME)
        }
        # 予約変更(番組名と放送時間変更)
        else {
            $message = $ExecutionContext.InvokeCommand.ExpandString($Config.TEMPLATE_CHG_BOTH)
        }
    }
    
    # 録画開始
    "PostRecStart" {
        $message = $ExecutionContext.InvokeCommand.ExpandString($Config.TEMPLATE_REC_START)
    }

    # 録画終了
    "PostRecEnd" {
        $fs = Get-FileSizeEx $filePath
        $driveSpace = Get-DriveSpaceText $filePath
        $programSummary = Get-ProgramSummary $filePath

        # 結果整理
        $resultMain = "録画終了"
        $commentText = ""

        switch ($result) {
            "録画終了" { }
            "終了" { }
            "録画中にキャンセルされた可能性があります" { $commentText = $result }
            "次の予約開始のためにキャンセルされました" { $commentText = $result }
            "開始時間が変更されました" { $commentText = $result }
            "録画終了（空き容量不足で別フォルダへの保存が発生）" { $commentText = "空き容量不足で別フォルダへの保存が発生" }
            default { if ($result) { $commentText = $result } }
        }

        # 0B のときだけ失敗
        if ($fs.SizeText -eq "0B" -or $fs.Status -eq "ZERO") {
            $resultMain = "録画失敗"
            $dropsIcon = "⚠️"
        }
        $sizeText = $fs.SizeText

        # 番組内容の組み立て
        $quotedSummary = ""
        if ($programSummary) {
            $quotedSummary = "`n" + (($programSummary -split "`r?`n" | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { ">" } else { "> $_" }
            }) -join "`n")
        }
		
		# $commentText がある時だけ、見出し付きの文字列に化けさせる
		if ($commentText) { 
			$commentText = " Comment:**$commentText**"
		} else {
			$commentText = "" # 正常終了時は完全に無
		}
        # 最終メッセージ展開
        $message = $ExecutionContext.InvokeCommand.ExpandString($Config.TEMPLATE_REC_END)
		$mention = ""

		if ($ALERT_MENTION -and
			(Test-NeedAlertMention $dropCount $result $fs.Status))
		{
			$mention = "$ALERT_MENTION "
		}
    }
}

if (-not $message) { return 'skip' }

# =========================
# 送信先の決定
# =========================


$eventWebhook = switch ($mode) {
    "PostAddReserve" { $WEBHOOK_ADD_RESERVE }
    "PostChgReserve" { $WEBHOOK_CHG_RESERVE }
    "PostRecStart"   { $WEBHOOK_REC_START }
    "PostRecEnd"     { $WEBHOOK_REC_END }
}

if (Test-WebhookUrl $eventWebhook) {
    $targetWebhook = $eventWebhook
} else {
    if ($eventWebhook) { Debug-Print "⚠️ $mode 用の Webhook URL が正しくないので、DISCORD_WEBHOOK_URL に送ります。" }
    $targetWebhook = $DISCORD_WEBHOOK_URL
}

if (-not (Test-WebhookUrl $targetWebhook)) {
    Debug-Print "❌ Webhook URL が設定されていません。config.psd1 の DISCORD_WEBHOOK_URL に、Discord でコピーした Webhook URL を書いてください。"
    return 'fail'
}

# =========================
# Discord送信
# =========================


$content = $message
if ($mention) {
    $content = $mention + $message
}
$payload = @{
    username   = $DISCORD_USERNAME
    avatar_url = $DISCORD_AVATAR
    content    = $content
} | ConvertTo-Json -Depth 5 -Compress



# 録画終了のみ、共有サムネイル (メイン処理で全ターゲット分を1回だけ生成) を添付して送信する
# 生成できていない場合や、このターゲットでサムネイル無効の場合は通常のテキスト送信にフォールバック
$sent = $false
if ($mode -eq 'PostRecEnd' -and $ENABLE_REC_THUMBNAIL -and $SharedThumbPath) {
    # 画像は embed で表示する (添付ファイル名 thumbnail.jpg を attachment:// で参照)
    $embedPayload = @{
        username   = $DISCORD_USERNAME
        avatar_url = $DISCORD_AVATAR
        content    = $content
        embeds     = @(@{ color = 0x5B7C99; image = @{ url = 'attachment://thumbnail.jpg' } })
    } | ConvertTo-Json -Depth 5 -Compress
    $sent = Send-DiscordWebhookWithFile -Url $targetWebhook -Body $embedPayload -FilePath $SharedThumbPath
    if (-not $sent) { Debug-Print "⚠️ 画像付き送信に失敗したので、テキストのみで送信します" }
}
if (-not $sent) {
    if (-not (Send-DiscordWebhook -Url $targetWebhook -Body $payload)) { return 'fail' }
}
return 'ok'

}

# =========================
# メイン処理
# =========================
$mode = $args[0]
if (-not $mode) { exit }

$eligibleTargets = @($NotifierTargets | Where-Object { -not $_.Modes -or $_.Modes -contains $mode })
if ($eligibleTargets.Count -eq 0) { exit }

# 録画終了サムネイルは、全ターゲット分をここで1回だけ生成して共有する
# (生成に使う設定は、サムネイル有効な最初の対象ターゲットの config から取る)
$sharedThumb = $null
if ($mode -eq 'PostRecEnd') {
    foreach ($t in $eligibleTargets) {
        if (-not (Test-Path -LiteralPath $t.ConfigPath)) { continue }
        try { $tc = Import-PowerShellDataFile -LiteralPath $t.ConfigPath } catch { continue }
        $thumbEnabled = $tc.ENABLE_REC_THUMBNAIL
        if ($null -eq $thumbEnabled) { $thumbEnabled = $true }
        if (-not $thumbEnabled) { continue }
        $ENABLE_REC_THUMBNAIL = $true
        $FFMPEG_PATH = $tc.FFMPEG_PATH
        if (-not $FFMPEG_PATH) { $FFMPEG_PATH = 'C:\ffmpeg\ffmpeg.exe' }
        $THUMB_COLS = $tc.THUMB_COLS
        if (-not $THUMB_COLS) { $THUMB_COLS = 6 }
        $THUMB_ROWS = $tc.THUMB_ROWS
        if (-not $THUMB_ROWS) { $THUMB_ROWS = 6 }
        $script:TargetName = $t.Name
        $sharedThumb = New-RecThumbnail -TsPath (Get-Env FilePath)
        break
    }
}

$anyFail = $false
foreach ($t in $eligibleTargets) {
    $script:TargetName = $t.Name
    try {
        $r = Invoke-NotifierTarget -ConfigPath $t.ConfigPath -SharedThumbPath $sharedThumb | Select-Object -Last 1
    } catch {
        Debug-Print "❌ 処理中に例外が発生しました: $($_.Exception.Message)"
        $r = 'fail'
    }
    if ($r -eq 'fail') { $anyFail = $true }
}
$script:TargetName = $null

if ($sharedThumb) { Remove-Item -LiteralPath $sharedThumb -Force -ErrorAction SilentlyContinue }
if ($anyFail) { exit 1 }
