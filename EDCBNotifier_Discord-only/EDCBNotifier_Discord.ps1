[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
# EDCBDiscordNotifier シンプル版 (局ロゴ・空き容量・番組概要の表示はありません)
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
$ENABLE_DROP_MENTION  = $Config.ENABLE_DROP_MENTION
$ENABLE_ERROR_MENTION = $Config.ENABLE_ERROR_MENTION
# メンション先 (config.psd1 の MENTION_ID。旧名 ALERT_MENTION にも対応)
$ALERT_MENTION        = $Config.MENTION_ID
if (-not $ALERT_MENTION) { $ALERT_MENTION = $Config.ALERT_MENTION }
# 未記入のサンプル値 "<@>" などはメンション無しとして扱う
if ($ALERT_MENTION -match '^\s*<@[!&]?>\s*$') { $ALERT_MENTION = "" }

# 配列オブジェクトの変換（明示的に型を固定）
$ALLOW_SERVICES         = [string[]]$Config.ALLOW_SERVICES
$ALLOW_TITLES           = [string[]]$Config.ALLOW_TITLES
$DENY_SERVICES          = [string[]]$Config.DENY_SERVICES
$DENY_TITLES            = [string[]]$Config.DENY_TITLES

# =========================

# =========================
# 共通関数
# =========================
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
        Write-Host $Text -ForegroundColor DarkGray
    }
}
# =========================
# メイン
# =========================

$mode = $args[0]
if (-not $mode) { exit }

$title      = Escape-DiscordMarkdown (Get-Env "Title")
$title_old  = Escape-DiscordMarkdown (Get-Env "TitleOLD")
$service    = Escape-DiscordMarkdown (Get-Env "ServiceName")
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
# 26.11.14 中身のない URL (config.psd1 の初期値 "https://discord.com/api/webhooks/" など) は未設定として扱う
function Test-WebhookUrl {
    param([string]$Url)
    return ($Url -match '^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/\d+/[\w-]+')
}

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
    exit 1
}

# =========================
# Discord送信
# =========================
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

$content = $message
if ($mention) {
    $content = $mention + $message
}
$payload = @{
    username   = $DISCORD_USERNAME
    avatar_url = $DISCORD_AVATAR
    content    = $content
} | ConvertTo-Json -Depth 5 -Compress

if (-not (Send-DiscordWebhook -Url $targetWebhook -Body $payload)) { exit 1 }
