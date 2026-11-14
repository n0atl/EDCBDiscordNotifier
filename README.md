# EDCBDiscordNotifier シンプル版 (PowerShell)

EDCB（EpgTimer）の予約・録画を Discord に通知する PowerShell 製のツールの、シンプルな版です。
局ロゴ・空き容量・番組概要の表示が必要な場合は、[main ブランチ](https://github.com/n0atl/EDCBDiscordNotifier/tree/main) の通常版を使ってください。

## 主な機能

* イベント通知（予約追加・予約変更・録画開始・録画終了）
* 予約変更の検知（番組名・放送時間・その両方の変更前と変更後を表示）
* プログラム予約・EPG自動予約の表示
* 録画終了時の Drop / Scramble 数、TS ファイルサイズ、録画結果
* 録画失敗時・Drop 発生時のメンション（設定可能）
* 放送局名・番組名による許可/拒否リスト
* イベントごとの送信先とメッセージのテンプレート

| イベント | バッチファイル |
| ---- | ---- |
| 予約追加 | `PostAddReserve.bat` |
| 予約変更 | `PostChgReserve.bat` |
| 録画開始 | `PostRecStart.bat` |
| 録画終了 | `PostRecEnd.bat` |

## 導入方法

1. `EpgTimer.exe` があるフォルダへ、`EDCBNotifier_Discord-only` フォルダと 4 つのバッチファイルをコピーします。
2. `EDCBNotifier_Discord-only\config.psd1` を開き、`DISCORD_WEBHOOK_URL` に Discord の Webhook URL を書きます。
   イベントごとに通知チャンネルを分けたい場合は、個別の Webhook URL も指定してください。

既にバッチファイルがある場合は、末尾に次の行を追加してください（`PostAddReserve` は各イベント名に変えてください）。

```bat
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0EDCBNotifier_Discord-only\EDCBNotifier_Discord.ps1" PostAddReserve
```

## フィルタ設定

`config.psd1` で、通知を許可する／しない放送局名・番組名を指定できます。
未指定（空配列）の場合は、すべて通知されます。
サービス名が全角英数字の場合は、半角へ変換せずそのまま記述してください。

```powershell
ALLOW_SERVICES = @("ＮＨＫ", "ＴＢＳ")
DENY_TITLES    = @("通販")
```

## メンション通知

`config.psd1` の `MENTION_ID` にメンション先を書くと、次のときにメンションします（個別に有効／無効を設定できます）。

* Drop 発生時
* 録画失敗・EDCB エラー時

## 免責事項

本スクリプトの利用により発生したいかなる損害についても、製作者は責任を負いません。
設定内容によっては通知が正しく行われない場合があります。導入後はテスト録画などで正常に動作することを確認してください。
