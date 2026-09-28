# ここだよ — 現在地と実測表

> 計画(日程・完了条件・降りる条件)の正本は [PLAN-2026-09-11.md](PLAN-2026-09-11.md)。
> このファイルは「いま何ができていて、何が残っていて、誰の手番か」と「実測の数字」だけを置く。コミットごとに更新する。

## プロダクト

待ち合わせで「もう着いてる」「どこ?」の電話をなくすアプリ。片方が**待つ**、もう片方が**迎えに行く**。UWBで相手までの残り距離(と、出る端末なら方向)が同じダイヤルに出る。

- 出自: 41h0(シホ)さんの支援アプリ「Arch」(#都知事杯オープンデータハッカソン)をUWBから再現したものが土台(2026-08-29)。8/31に合流アプリへ転換し、題材・文言・配色・アイコン・バンドルID・画面構成をすべて変更。**対外的に語るときは出自を明示する**
- バンドルID `jp.shutanuma.kokodayo` / 表示名「ここだよ」/ private repo `shoujiki-panman/arch-reproduction`
- 技術: NearbyInteraction + MultipeerConnectivity + ARKitカメラアシスト。1ピア1NIセッション。役割はセグメント切替。デモモード(実測なしの模擬)あり

## Phase 0 の記録欄(本人が3行埋める)

- 貸し手 = (誰 / 機種 / iOS)
- 実測日 = (日付)
- BootCamp発表会 = (日付。一次情報で確認)

## 事実(実測・機械確認したもの)

- 2026-09-29 0:41 実機2台: 本当は2mなのに全画面・ロック画面が **GPSの15m**。片方がロック画面＝アプリが裏＝MultipeerConnectivity が切れて電波の距離は出ない（9/12の制約どおり）。カメラ画面では `-5883` の「方向を表示できません」も再発（9/12の分岐5は未決のまま）。→ GPSの誤差の内（20m か精度×2 以内）は数字を出さず「すぐ近く」と言う（ecc6ab2）。床の地図は北が上で文字が逆さま・範囲220mで相手の印が隠れていた → 向いている方を上・相手が近いと寄る（ecc6ab2）。閉じた瞬間に島を「古い」にしていた → 裏で位置を取るあいだは地図の居場所で島を更新
- 2026-09-12: 🚨**両方がアプリを開いたままでないと成立しない**。Appleドキュメント: アプリが背面に回ると MultipeerConnectivity は広告も探索も止め、開いているセッションを切断する。つまり迎える側は歩いている間ずっと画面を見ている必要があり、ポケットに入れた瞬間に切れる。純正「探す」の Precision Finding はシステム側なのでこの制約を受けない（正面から勝てない差）
- 2026-09-12 屋外・本人以外と初使用: ①**役割が分からない**（「相手が使い方わからないとどっちが何していいかわからない」）→ PR#24 で両画面に指示を出した ②**両方が最初に開くのが面倒**（本人の判断は「手数の話。使うのはいい」＝UWBの価値は認める）→ 迎える側は PR#25 のリンクで1タップに。待つ側の起動はまだ削れる（前回の選択を覚える／ウィジェット）
- 2026-09-12: **カメラアシストは通る。ただし収束に32秒**（16 Pro 2台・室内・3m前後）。当初 `-5883 NIErrorCodeInvalidARConfiguration` で測距ごと死んでいたが、原因は**こちらが渡していた ARWorldTrackingConfiguration が NI と非互換**だったこと。NIに自前でARSessionを作らせると `err` なし・`cb/s=64〜67`・`world_nil=0` で収束する。ただしその経路では**カメラ映像がこちらに来ない**。`direction` は終始 nil のままで、**方向の出どころは worldTransform だけ**
- 2026-09-12: **迎える側の名前が両方「iPhone」**。iOS 16以降 `UIDevice.current.name` は `com.apple.developer.device-information.user-assigned-device-name` entitlement なしでは機種名しか返さない。ROADMAPに【推測】で置いていた表示名の項目が実機で裏取りされた
- 2026-09-12: **HUDが画面最下端でホームインジケータと重なり、タップできない**（3回タップの展開・長押しの共有が実機で使えない）
- 2026-09-12: **借りた2台目も iPhone 16 Pro (iOS 26.6.2)**。`-previewCaps` で機械取得: `preciseDistance=true / direction=false / cameraAssist=true / extendedDistance=true`。端末Aと同一。→ **生の方向は2台とも出ないことが確定**。実測表の項目1(方向 3m/5m/10m)は実施せず、項目0'(迎える側のカメラアシストで world_nil が 0 になるか)に置き換える
- 2026-09-11: **実機 iPhone 16 Pro (iOS 26.6) の NISession.deviceCapabilities**(`-previewCaps` で機械取得): `supportsPreciseDistanceMeasurement=true / supportsDirectionMeasurement=false / supportsCameraAssistance=true / supportsExtendedDistanceMeasurement=true`。→ この端末では生の `direction` は出ない。方向が出る可能性が残るのは**迎える側のカメラアシスト(worldTransform)だけ**。待つ側のダイヤル矢印は成立しない
- 2026-09-12: **迎える側のPhase復帰3件をシミュレータ2台で実測**。(2) `arrived` → 相手アプリ終了 → `searching` に戻りAR画面が閉じる。(8) `arrived` 中に同じ待ち手が meet を再送 → `arrived` のまま(以前は `ready` に落ちて閉じた)。(4) `arrived` 中に 1.6m(=到着1.0m+ヒステリシス0.5m+0.1) を流す → `guiding` に戻る。ヒステリシス0.5mは暫定で、実測表4行目の揺れ幅が出たら置き換える
- 2026-09-11: **シミュレータ2台でMultipeerConnectivity接続とNearbyInteractionの模擬測距(0.04m固定)が動く**。hello→トークン→meet→finish→再接続の全経路をログで確認。実機2台が無くても状態遷移の回帰確認はできる(方向・実距離は模擬なので実測の代わりにはならない)。シミュレータも `sup_dir=0`
- 2026-09-11: Apple 109512 原文: 日本では規制で一部UWB周波数が不可、**Find People**・拡張Precision Finding・Apple WatchのPrecision Findingが利用不可、前世代チップ相当の性能(2026-03-27公開)。→ 純正「探す」の人の精密検索(iOS 17+、iPhone 15以降同士)は日本では使えない。空き地は日本限定
- 2026-09-11: CMAltimeter は `NSMotionUsageDescription` 必須(Apple原文: 無いとクラッシュ)。追加済み
- 2026-08-31: App Clip では Nearby Interaction が実行時無効(Apple公式)。iOS Safari に Web Bluetooth / WebXR / UWB API なし。→ 配布は TestFlight / App Store のみ

## 残っているもの(番号は PLAN-2026-09-11 の監査表に対応)

| # | 何 | 状態 | 手番 |
|---|---|---|---|
| 1 | デモボタンが実測を乗っ取る | ✅ PR#1 (9/11) | — |
| 3 | peerEnded後に再接続できない | ✅ PR#2 (9/11) シミュレータ2台で検証 | — |
| 12a | DEVELOPMENT_TEAM が空 | ✅ PR#4 (9/11) | — |
| HUD | 計測HUD(実測日の計測器) | ✅ PR#3 (9/11) DEBUGのみ | — |
| 2 | 切断してもAR画面から戻らない | ✅ PR#6 (9/12) シミュレータ2台で検証 | — |
| 4 | 「見つけた」から戻れない | ✅ PR#6 (9/12) ヒステリシス0.5m(暫定)・シミュレータで検証 | — |
| 8 | 同じ相手の再送でAR画面が閉じる | ✅ PR#6 (9/12) シミュレータ2台で検証 | — |
| 配布 | ITSAppUsesNonExemptEncryption=NO / armv7→arm64 / DEPLOYMENT_TARGET=15.0固定 / CFBundleVersionを上げる / URLSession等の不使用grep / PrivacyInfo(UserDefaults時) | Phase 2 必須 | AI |
| MPC | 識別子が Apple サンプルのまま(`nisample`)→ `_kokodayo._tcp` | Phase 2 必須。合流1件で検証 | AI |
| 5 | 待つ側が切断に気づけない | Phase 2 次点 | AI |
| 13 | 迎える側の「合流を終える」が待つ側に届かない(DoneMessage) | Phase 2 次点 | AI |
| 14 | didInvalidateWith が権限以外のエラーで link を消す | Phase 2 次点(HUDのエラーコードを見てから) | AI |
| 7 | AR画面でデモと実測の区別がつかない | Phase 2 次点(デモバッジ) | AI |
| 9 | 「合流」「見つけた」の呼び方割れ | Phase 2 次点 | AI |
| 11 | README が Apple サンプルの英文 | Phase 2 次点(出自明記) | AI |
| 文言 | 「伝えている間だけ届く」と実装(常時測距・表示だけ隠す)のずれ | 問2で本人が決める(推奨=文言側を直す) | 本人 |
| 表示名 | UIDevice.name が「iPhone」になりうる【推測】 | 実測 項目0で確認してから | AI |
| 見た目 | デザインの作り直し(骨組みだけArch期`ceecf1b`から回収、文言・配色・題材・#7119は戻さない)＋Appleデザイン原則の適用 | Phase 2・**実測日のあと**(2026-09-12 本人決定。詳細はPLAN) | AI／スキルURLは本人 |
| 6 | 小画面で見出しが潰れる(13 mini 確認済み) | Phase 3(mini級のテスターがいる時) | AI |
| 16 | maxPeers=3 で4台目から相手が出ない | Phase 3(4台以上の場で起きたら) | AI |
| 10 | VoiceOver / Dynamic Type | Phase 4以降 | — |
| 12c | ターゲット名 NIPeekaboo / アイコンのファイル名 / Main.storyboard 残骸 | Phase 4以降 | — |
| 15 | MeetRequest の ack が無い | Phase 4以降 | — |

## 実測表(Phase 1、空欄を埋める)

実測日: ____ / 場所: ____ / 端末A: 16 Pro (iOS 26.6) / 端末B: **16 Pro (iOS 26.6.2)** / 貸し手の記事掲載可否: ____

> 2026-09-12: 借りられる端末が**同じ16 Pro**と判明。両方 `direction=false` が確定しているので、項目1(方向 3m/5m/10m)は測らず項目0'(カメラアシストのworld_nil)に置き換える。当日の順番と記入欄は **MEASURE-SHEET.md** にまとめた。

| # | 項目 | 結果 |
|---|---|---|
| 0 | 冒頭: 権限3つ(ローカルネットワーク/NI/カメラ)両端末で許可・自動ロックなし・相手一覧の名前が区別できるか・HUD の sup_dir/sup_cam(端末B)・他端末の混入なし・距離1つ出る | |
| 0' | 端末Bの sup_dir が 0 → 項目1は省略し、迎える側AR画面で world_nil が 0 になるか(端末を左右に振る) | |
| 1 | 方向: 3m/5m/10m × 60秒静止。迎える側=AR画面の world_nil と conv/conv_reasons、待つ側=ダイヤルの dir_nil。役割入替でもう1周 | |
| 1' | 補助: 同じ2台に findme を入れて矢印が出るか(断定には使わない) | |
| 2 | 見通し距離: 5m刻みで接続維持/切断 ×3。戻って再接続するか。固まったら ni_error | |
| 3 | 1m到着判定: 10回中の発火回数 / 1.5m以上での誤発火回数 | |
| 4 | 歩行中・人混みでの矢印の暴れ(方向が出た場合のみ、3段階目視) | |
| 5 | 気圧: 階段1フロアで rel_alt_m の差 | |
| 6 | 余力: 壁1枚 | |
| 7 | 両端末とも Wi-Fi 未接続(モバイル通信のみ、Wi-Fi/BT の電波は ON)で相手一覧に出るか | |
| 8 | 合流の瞬間 ×3: 待つ側が画面を見ずに先に見つけた回数 / 迎える側が最後に頼ったのは 矢印・距離・目印 のどれ | |
| 9 | 失敗の再現: 圏外→戻る / 相手がアプリを閉じる→開き直す / 迎える側が「合流を終える」→ 各画面が戻れたか固まったか | |
| 10 | 任意: 実機2台を横から30秒撮る(了承後) / 純正「探す」で人の精密検索が出ないことの写真(両方15以降のときだけ) | |
| 判定 | 接続(10m以上/5〜10m/5m未満)・方向(出る/カメラアシスト後のみ/出ない)・1m判定(n/10) | |

CSVは HUD を長押しして共有→ `measurements/` に置く。端末名・持ち主名は「端末A/B」に置換してからコミット。

## 運用メモ

- ビルド(実機): `xcodebuild -project NIPeekaboo.xcodeproj -scheme NIPeekaboo -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=59FNRWS2H8 CODE_SIGN_STYLE=Automatic build` → `xcrun devicectl device install app --device <UDID> <.app>`
- 機械確認(端末不要): `xcodebuild ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- 借りた端末にケーブルで入れる: ①設定→プライバシーとセキュリティ→デベロッパモードON→再起動 ②ロック解除したままMacに接続→「信頼」 ③上のビルドコマンドでインストール(初回は「デベロッパを信頼」)
- 実機の能力フラグ: `xcrun devicectl device process launch --console --terminate-existing --device <UDID> jp.shutanuma.kokodayo -- -previewCaps`
- シミュレータ2台の回帰確認: 片方 `-previewFinder -previewAutoFinish -previewLog`、もう片方 `-previewAutoSend -previewLog`(`--console-pty` でログ取得、`RECON` 行を見る)
- Phase復帰の確認(欠陥2/4/8): 迎える側 `-previewFinder -previewAutoGuide -previewDrift -previewLog` ＋ 待つ側 `-previewAutoSend -previewResend -previewLog`。`-previewAutoGuide`=meet受信2秒後にAR画面へ / `-previewDrift`=到着後に1回だけ範囲外の距離を流す(シミュレータの模擬距離は0.04m固定で動かせないため) / `-previewResend`=14秒後に同じ meet を再送。切断は `xcrun simctl terminate <UDID> jp.shutanuma.kokodayo`
- 実測日まで 16 Pro は iOS 26.6 のまま(Xcode 26.6 / SDK 26.5 と揃える)。iOS 27 には上げない
- 🚨**屋外で距離を測るときは2人とも画面を点けたままにする**。片方が画面を消すか他のアプリに行った瞬間にMPCが切れるので、そのままだと「5mで切れた」という嘘の数字になる。DEBUGビルドは `isIdleTimerDisabled` を立てているので自動ロックはしないが、手で消すと切れる
- 🚨外出中の端末にMacからインストールはできない（同じLANが要る）。ケーブルは必須ではないが、Wi-Fiが別なら無理。これを解消するのはTestFlight（Phase 2の本人タスク）
- 🚨実機の署名ビルドで `-derivedDataPath` をこのリポジトリの中に向けてはいけない。リポジトリが同期フォルダ配下(`com.apple.fileprovider.*` が付く)にあるため、成果物に `com.apple.FinderInfo` が付いて `CodeSign` が `resource fork, Finder information, or similar detritus not allowed` で落ちる。既定のDerivedData(`~/Library/Developer/Xcode/DerivedData`)に出せば通る。シミュレータ向けは署名しないので影響なし(2026-09-12 実測)
- 🚨**端末Aは画面表示ズームが入っている**(2026-09-12 実測: panelFrame=320×501、標準の16 Proは402×641)。文字サイズは最小(XS)。シミュレータの16 Pro/17 Proでは2割広いので、レイアウトの検証はこれだけでは足りない。溢れの確認は iPhone SE 級(375×667)か実機で行う
- 匿名化: CSV・スクショ・記事の端末名は「端末A/B」に置換してからコミット
