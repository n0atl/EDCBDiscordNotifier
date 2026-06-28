# EDCBNotifier Discord only (PowerShell版)

EDCB（EpgTimer）の予約・録画状況をDiscordへ通知するPowerShell製のツールです。
<img src="https://github.com/user-attachments/assets/414e0e1e-edcd-4f7a-82aa-871946110d93" width="500" alt="通知イメージ">
## 主な機能

* イベント通知

  * 予約追加
  * 予約変更
  * 録画開始
  * 録画終了
* 予約変更検知

  * EPG更新などによる予約変更時に、変更前と変更後の情報を表示
* EPGロゴ表示
  * EPGロゴをカスタム絵文字として表示

  * Drop発生時や空き容量低下時に警告表示
  * 録画ファイルサイズの計測
  * 保存先ドライブの空き容量表示
  * `program.txt` から番組概要を抽出して引用投稿
* フィルタリング

  * 放送局名・番組名による許可/拒否リストに対応

---

# 通知されるイベント

以下のEDCBイベントに対応しています。

| イベント | バッチファイル          |
| ---- | ---------------- |
| 予約追加 | `PostAddReserve` |
| 予約変更 | `PostChgReserve` |
| 録画開始 | `PostRecStart`   |
| 録画終了 | `PostRecEnd`     |

### 予約変更通知

予約変更時は以下を判別して通知します。

* 番組名変更
* 放送時間変更
* 番組名・放送時間の両方変更

---

# 導入方法

## 1. ファイルの配置

`EpgTimer.exe` があるフォルダへ、`EDCBNotifier_Discord-only` フォルダをコピーしてください。

---

## 2. 本体設定

`config.psd1` をテキストエディタで開き、設定項目を環境に合わせて編集してください。

### 必須設定

Discord Webhook URL

イベントごとに通知チャンネルを分けたい場合は、個別のWebhook URLを指定してください。

### EPGロゴ絵文字（任意）

`DTVlogo.json` 内に、ご自身の環境で受信可能な放送局名と絵文字IDを追加してください。

---

## 3. バッチファイルの設定

### A. 新規導入

`EpgTimer.exe` と同じフォルダへ以下のバッチファイルを配置してください。

* `PostAddReserve.bat`
* `PostChgReserve.bat`
* `PostRecStart.bat`
* `PostRecEnd.bat`

### B. 既にバッチファイルが存在する場合

既存のバッチファイルの末尾（または適切な場所）へ、以下を追加してください。

※ `PostAddReserve` の部分は各イベントに合わせて変更してください。

```bat
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0EDCBNotifier_Discord-only\EDCBNotifier_Discord.ps1" PostAddReserve
```

---

## 4. 動作

設定完了後は、EDCBのイベント発生時にDiscordへ通知されます。

---

# 通知内容

## 共通

* 放送局名
* 番組名
* 放送日時

## 録画終了時のみ

* Drop / Scramble数
* TSファイルサイズ
* 録画保存先ドライブの空き容量

---

# フィルタ設定

`config.psd1` 内で以下のフィルタを設定できます。

* 通知を許可する放送局名
* 通知を許可する番組名
* 通知しない放送局名
* 通知しない番組名

未指定（空配列）の場合は、すべて通知されます。

サービス名が全角英数字の場合は、半角へ変換せずそのまま記述してください。

## 設定例

```powershell
ALLOW_SERVICES = @("ＮＨＫ", "ＴＢＳ")
DENY_TITLES    = @("通販")
```

---

# 免責事項

本スクリプトの利用により発生したいかなる損害についても、製作者は責任を負いません。

設定内容によっては通知が正しく行われない場合があります。導入後はテスト録画などで正常に動作することを確認してください。
