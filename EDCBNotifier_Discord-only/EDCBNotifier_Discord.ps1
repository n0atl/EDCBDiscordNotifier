[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$PSDefaultParameterValues['ConvertTo-Json:Encoding'] = 'utf8'
$IsFromEDCB = $env:ServiceName -or $env:Title -or $env:FilePath

# =========================
# 設定読み込み (config.psd1)
# =========================
$configPath = Join-Path $PSScriptRoot "config.psd1"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.psd1が見つかりません: $configPath"
    exit 1
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
$ALERT_MENTION        = $Config.ALERT_MENTION

# PSD1側で「100GB」と書いたデータがそのまま実バイト数として入ります
$DRIVE_ALERT_THRESHOLD  = $Config.DRIVE_ALERT_THRESHOLD

# 配列オブジェクトの変換（明示的に型を固定）
$ALLOW_SERVICES         = [string[]]$Config.ALLOW_SERVICES
$ALLOW_TITLES           = [string[]]$Config.ALLOW_TITLES
$DENY_SERVICES          = [string[]]$Config.DENY_SERVICES
$DENY_TITLES            = [string[]]$Config.DENY_TITLES

# =========================

# =========================
# 共通関数
# =========================
# 局ロゴ追加 26.02.14
# 局ロゴ追加 26.06.27 JSON外部参照方式に変更
# =========================
function Get-ServiceEmoji {
    param([string]$ServiceName)
    if (-not $ServiceName) { return "" }
    $jsonPath = Join-Path $PSScriptRoot "DTVlogo.json"
    if (-not (Test-Path -LiteralPath $jsonPath)) { return "" }
    try {
        $emojiMap = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($key in $emojiMap.psobject.Properties.Name) {
            if ($ServiceName -like "*$key*") {
                return $emojiMap.$key
            }
        }
    } catch {}
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
    if (-not $Keywords -or $Keywords.Count -eq 0) {
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
    if (-not $Keywords -or $Keywords.Count -eq 0) {
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
# メイン
# =========================

$mode = $args[0]
if (-not $mode) { exit }

# =========================
# 局ロゴ追加 26.02.14
$serviceRaw = Get-Env "ServiceName"
$discord_emoji = Get-ServiceEmoji $serviceRaw
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
        exit
    }
    if (Test-DenyByKeyword $title $DENY_TITLES) {
        Debug-Print "❌ DENY: 指定した番組名により除外されました"
        exit
    }
    # --- ALLOW
    if (-not (Test-AllowByKeyword $service $ALLOW_SERVICES)) {
        Debug-Print "❌ ALLOW: Service が許可リストに含まれていません"
        exit
    }

    if (-not (Test-AllowByKeyword $title $ALLOW_TITLES)) {
        Debug-Print "❌ ALLOW: Title が許可リストに含まれていません"
        exit
    }

    Debug-Print "✅フィルタ通過"
}
else {
    Debug-Print "🛠️EDCB以外からの実行（デバッグモード）"
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
        if (-not ($titleChanged -or $timeChanged)) { exit }

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

if (-not $message) { exit }

# =========================
# 送信先の決定
# =========================
$targetWebhook = $DISCORD_WEBHOOK_URL

switch ($mode) {
    "PostAddReserve" { if ($WEBHOOK_ADD_RESERVE) { $targetWebhook = $WEBHOOK_ADD_RESERVE } }
    "PostChgReserve" { if ($WEBHOOK_CHG_RESERVE) { $targetWebhook = $WEBHOOK_CHG_RESERVE } }
    "PostRecStart"   { if ($WEBHOOK_REC_START)   { $targetWebhook = $WEBHOOK_REC_START   } }
    "PostRecEnd"     { if ($WEBHOOK_REC_END)     { $targetWebhook = $WEBHOOK_REC_END     } }
}

# 送信先が結局空なら終了
if (-not $targetWebhook) { 
    Debug-Print "❌ 送信先Webhook URLが設定されていません。"
    exit 
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

Invoke-RestMethod `
    -Uri $targetWebhook `
    -Method Post `
    -ContentType 'application/json; charset=utf-8' `
    -Body $payload