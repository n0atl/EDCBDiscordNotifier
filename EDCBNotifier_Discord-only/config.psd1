@{
# 共通の送信先（個別指定がない場合はここが使われます）
DISCORD_WEBHOOK_URL = "https://discord.com/api/webhooks/"

# --- モード別個別送信先 (空欄 "" の場合は共通URLを使用) ---
WEBHOOK_ADD_RESERVE = ""
WEBHOOK_CHG_RESERVE = ""
WEBHOOK_REC_START　= ""
WEBHOOK_REC_END　= ""

# --- Discord表示設定 ---
DISCORD_USERNAME = "EDCBNotifier"
DISCORD_AVATAR　= "https://raw.githubusercontent.com/EMWUI/EDCB_Material_WebUI/master/HttpPublic/EMWUI/img/android-chrome-192x192.png"

# --- 空き容量表示・警告設定 ---
ENABLE_DRIVE_INFO  = $true		# 容量情報自体を表示するか ($true = する / $false = しない)
ENABLE_DRIVE_ALERT = $true		# 警告絵文字を表示するか ($true = する / $false = しない)
DRIVE_ALERT_THRESHOLD = 100GB	# 警告を出す残り容量 (例: 100GB, 50GB, 1TB)

# --- メンション設定 ---
# Drop数が1以上の録画終了時にメンションする
ENABLE_DROP_MENTION = $true

# 録画失敗やEDCBエラー時にメンションする
# 対象:
# ・録画開始処理に失敗しました
# ・チューナーのオープンに失敗しました
# ・ファイル保存で致命的なエラーが発生した可能性があります
# ・TSファイルサイズが0B
ENABLE_ERROR_MENTION = $true

# メンション先
# 例 MENTION_ID = "<@DiscordのユーザーID>"
MENTION_ID = "<@>"


# --- フィルター設定 ---
# 実行フィルタ
# 実行許可（空欄で全て通知 (例: @() )
# 通知を許可する放送局(サービス名が含まれる文字例) (例; @("大分", "CTBメディア", "愛媛", "松山", "あいテレビ") )
ALLOW_SERVICES = @()
# 通知を許可する番組名
ALLOW_TITLES　= @()
# 通知させない放送局(サービス名) (例; @("ＮＨＫＥテレ") )
DENY_SERVICES　= @("")
# 通知させない番組名
DENY_TITLES　= @()
	
# --- メッセージテンプレート設定 ---

# 利用可能な主な変数: $discord_emoji, $service, $NWN, $recCommentText, $startDate, $SDW, $startTime, $endTime, $title
# 予約追加
ADD_RESERVE = @'
📌 **予約追加** 【$discord_emoji$service$NWN】$recCommentText
> $startDate($SDW) $startTime～$endTime
> $title
'@

# ------------------
 # 予約変更時のみ利用可能な変数: $title_old, $timeOldText, $timeNewText
# 予約変更 (番組名のみ)
TEMPLATE_CHG_TITLE = @'
🔄**予約変更** 【$discord_emoji$service$NWN】$recCommentText
番組名が変更されました。
> $startDate($SDW) $startTime～$endTime
> [変更前]$title_old
> [変更後]$title
'@

# ------------------

# 予約変更 (時間のみ)
TEMPLATE_CHG_TIME = @'
🔄**予約変更** 【$discord_emoji$service$NWN】$recCommentText
放送時間が変更されました。
> $title
> [変更前]$timeOldText
> [変更後]$timeNewText
'@

# ------------------

# 予約変更 (番組名と時間両方)
TEMPLATE_CHG_BOTH = @'
🔄**予約変更** 【$discord_emoji$service$NWN】$recCommentText
番組情報が変更されました。
> [変更前]$title_old
> [変更後]$title
> [変更前]$timeOldText
> [変更後]$timeNewText
'@

# ------------------

# 録画開始
TEMPLATE_REC_START = @'
🔴 **録画開始** 【$discord_emoji$service$NWN】$recCommentText
> $startDate($SDW) $startTime～$endTime
> $title
'@
# ------------------

# 録画終了時のみ利用可能な変数: $dropsIcon, $resultMain, $quotedSummary, $drops, $scrambles, $sizeText, $driveSpace, $commentText
# 録画終了
TEMPLATE_REC_END = @'
$dropsIcon**$resultMain** 【$discord_emoji$service$NWN】$recCommentText
> $startDate($SDW) $startTime～$endTime
> $title$quotedSummary
> Drop:**$drops** Scramble:**$scrambles** TS:**$sizeText**$driveSpace$commentText
'@
}