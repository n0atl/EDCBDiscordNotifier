@{
    # 通知先 (Discord サーバー) の定義。
    # 追加する時は、config.psd1 のあるフォルダを用意して、Targets に1ブロック足すだけ。
    # Modes は担当するモード (省略した場合は全モード)。
    # あるターゲットの config 読み込みや送信に失敗しても、他のターゲットには影響しない。
    # このファイルが無い場合は、EDCBNotifier_Discord.ps1 と同じフォルダの config.psd1 のみが使われる。
    Targets = @(
        @{
            Name      = 'Main'
            ConfigDir = '.'
            Modes     = @('PostAddReserve', 'PostChgReserve', 'PostRecStart', 'PostRecEnd')
        }
        # 2つ目の通知先の例 (config.psd1 のあるフォルダを用意してからコメントを外す)
        # ,@{
        #     Name      = 'Second'
        #     ConfigDir = 'second-server'
        #     Modes     = @('PostChgReserve', 'PostRecStart', 'PostRecEnd')
        # }
    )
}
