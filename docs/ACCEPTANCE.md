# 驗收與證據

2026-10-23 Build 18 限制修復待真機複測：Build 16 已安裝於 iPhone 13；使用者確認主鬧鐘有聲，按「停止／開啟」會立即進入任務。當晚 06:30 鬧鐘設定於前一天 18:00 開始限制，21:00 卻沒有任何 App 被遮罩。手機唯讀資料顯示鬧鐘與限制開關均已保存，但 10/24 的事件在 18:53 被取消，之後重新啟用時未恢復。Build 17 在手機資料中已恢復該未來事件，但 App Group 未見 `restrictions-v1.json`，因此**不能宣稱限制已修復**。Build 18 改正共享檔寫入協調選項，並新增寫後讀回驗證；39 項核心測試與簽署 iPhoneOS 建置通過。iPhone 暫列 unavailable，Build 18 尚未安裝；須驗證共享檔、Home「限制中」及實際第三方 App 遮罩。

2026-10-05 Build 10 開發驗證：使用者提供的 Build 9 試做 JSON 記錄 590 個樣本、只計入 1 下；分析顯示舊計數器在第一次下壓後，大多卡在原始上位基準的回升條件。Build 10 改為以每一下的最低點計算肩膀回升，並以該份數值離線重播得到 10 下。36 項核心測試、iOS Simulator 完整編譯及簽署 iPhoneOS build 均通過。iPhone 13 目前被 Xcode 列為 unavailable，因此 Build 10 尚未安裝及取得新一輪真人結果。新增字串的英文與繁中已更新；其他語言使用英文回退，母語審校仍阻擋送審。

2026-10-04 Build 9 開發驗證：32 項核心測試與 iOS Simulator 編譯已通過，簽署的 Debug build 已安裝到 iPhone 13 並能啟動。iOS 27 模擬器 UI 測試進入 Testing 階段後超過 11 分鐘無案例結果，已停止；不能列為通過。尚無使用者完成十下、JSON 匯出、Safari 遮罩或在背景自動解除限制的觀察結果；這些不可列為通過。

更新：2026-09-22。通過表示有實際執行結果；待驗證不是通過。

## 已取得

| 驗證 | 證據 | 結果 |
| --- | --- | --- |
| iOS App + 3 個擴充套件完整編譯 | Xcode 27、iOS 17 deployment target | 通過 |
| 模擬器啟動 | iPhone 17 Pro / iOS 26.5，繁中 onboarding | 通過 |
| 19 項核心測試 | `swift test --scratch-path work/swift-build` | 19/19 通過 |
| 回饋欄位／公式防護／去重及失敗處理 10 項 | `node --test backend/feedback.test.cjs` | 10/10 通過；Apps Script API 為 mock，非正式部署 |
| 英語導覽、繁中、RTL、大字體邊界、試做出入共 5 項 UI | `work/UI-26.5-layout-fixed.xcresult` | 5/5 通過 |
| 同上 iOS 18.3.1，含最後提醒摘要修改 | `work/UI-18.3-verified.xcresult` | 5/5 通過 |
| 二十語言字串／格式完整性 | `tools/validate_localizations.py` | 20 × 160，通過；未母語校閱 |
| iPhone 裝置端未簽署編譯 | `work/DeviceBuild` / generic iOS | 通過；並非真機執行或有效簽署 |
| 送審門檻檢查 | `python3 tools/release_check.py` | NOT READY（預期；13 項缺少配置／證據） |

初輪 UI 測試有測試選擇器名稱錯誤（Create alarm vs Add alarm），已修正並重跑通過。另修正 Debug 與 SwiftPM 架構不一致的測試連結設定。這些不應隱藏或混同產品真機結果。

新增最大字體導覽與試做出入後，初輪雖通過，截圖仍抓到首頁水平溢出。已將無障礙字體下的七日／統計改為直列，加入文字 frame 不超出螢幕的斷言；修正後兩版各 5/5 通過，且人工檢查修正後截圖。提醒摘要修改曾出現括號編譯錯誤，修正後 iOS 18.3.1 與未簽署 iPhone 建置均通過。試做路由測試並非真實相機辨識測試。

## 2026-09-22 上架環境盤點

- 初版曾推送至私有 GitHub。2026-10-23 已將完整舊歷史保留於私有 `Chein-Shawn/okiru-private-archive`，另以乾淨單一提交建立公開、source-available 的 `Chein-Shawn/okiru`；不能將舊私有提交當成公開庫歷史。
- Apple Developer Team `3NFD3KU8Q8` 已確認；本機 `Config/Local.xcconfig` 已設定該 Team ID（檔案不進 Git）。
- 已在 Apple Developer 登記主 App、三個擴充套件與共享群組，並將四個 App ID 都關聯 `group.com.shawn.okiru`：
  - `com.shawn.okiru`
  - `com.shawn.okiru.OkiruMonitor`
  - `com.shawn.okiru.OkiruShield`
  - `com.shawn.okiru.OkiruShieldAction`
- 四個 App ID 已啟用 App Groups 與 Family Controls (Development)。2026-09-22 已提交 Family Controls (Distribution) 申請；Apple 回覆「We’ll review your request and contact you soon」，尚待核准，因此仍為阻擋項。
- App Store Connect 已建立 Okiru（Apple ID `6814670275`、iOS 1.0、繁體中文主要語言），並保存繁中宣傳文字、描述與關鍵字。
- iPhone 11 Pro Max / iOS 18.3.1 已產生 3 張繁中商店截圖（Home、Alarm、Settings，皆為 `1242 × 2688`）；加入截圖流程後的完整 UI 測試 `work/AppStoreFull-20260922.xcresult` 為 6/6 通過。三張截圖已上傳 App Store Connect，順序核對為 Home → Alarm → Settings。
- 帳號持有人已於 2026-09-22 接受更新版 Apple Developer Program License Agreement。App Store Connect 的 DSA 狀態已聲明為非貿易商，並顯示「通過審查」。
- `security find-identity -v -p codesigning` 現有 1 個有效 Apple Development 身分。2026-09-22 的 iPhone Release build 與 generic iOS archive 均已成功，四個 target 亦通過 embedded binary validation；App Store Connect 自動簽署匯出成功。
- `devicectl` 已偵測並配對實體 iPhone 13（iOS 26.7），裝置詳細資訊確認 `Developer Mode Status: Enabled`。重啟失效的 CoreSimulator／CoreDevice 服務後，Okiru 1.0.0 build 1 已成功安裝並啟動，且程序仍在執行；相機、通知、Screen Time 與響鈴行為仍須由使用者在裝置上互動驗收。可用模擬器 runtime 為 18.3.1、26.5、27.0；iOS 17 尚缺。
- 第一次 App Store 上傳由 Apple 驗證發現三個擴充套件缺少 `CFBundleDisplayName`；修正並重新封存後，Okiru 1.0.0 build 1 已於 2026-09-22 成功上傳並完成 Apple 處理。出口合規已聲明為未使用非豁免／自訂加密，build 狀態為「準備提交」。後續 build 已在 Info.plist 加入 `ITSAppUsesNonExemptEncryption = false`。
- App Store Connect 已保存副標題「用行動完成的起床鬧鐘」、主要類別「工具程式」、次要類別「健康與健身」、依實際內容回答的年齡分級（多數地區 9+），以及「不是受監管醫療器材」聲明。
- `Config/Services.json` 已填 App Store ID，以及 2026-09-23 在 `speech.vocaldive.com` 實際開啟驗證的正式隱私與支援 URL；回饋 URL 仍待 Google 授權與端到端測試。未取得 Family Controls 核准與真機證據，不得標為可上架。

## 必須由實體 iPhone 驗證

- [ ] iOS 17、18、26.0、26.1+ 與當前正式版；最低版本啟动。
- [ ] 單次、週期、同時、DST、跨日、時區移動、離線、強制關閉、重新開機。
- [ ] 靜音／專注：主鬧鐘 vs 追加通知的差異，系統 Stop 後不計成功。
- [ ] 滑掉提醒後仍有剩餘追加通知；48 筆容量及主鬧鐘不被擠掉；三小時後無殘留。
- [ ] 前鏡頭全身、骨架鏡像、不同衣著／身形／光線／擺位。
- [ ] 至少 5 位同意參與的使用者，30 組每組 10 下，至少 29 組完全正確。
- [ ] 非伏地挺身、半次、靜止、遮擋、多人不得誤判十下完成。
- [ ] 相機授權延遲、來電、前背景切換保留整次並重置半次。
- [ ] App 播放器音量維持 1.0；耳機、藍牙、來電、中斷恢復；不能宣稱強制調高系統音量。
- [ ] Screen Time 個人授權、Spotify 例外、其餘可封鎖 apps、不可限制的系統功能說明。
- [ ] 跨午夜，完成後延遲 15–120 分鐘，App 在背景時由 Monitor 自動解除；晚完成與重疊限制。
- [ ] 直接選取 Safari 遮罩、網站類別後備、仍無法限制的系統 App 說明。
- [ ] 5–100 下目標、五／十分鐘邊界、試做固定十下及歷史快照。
- [ ] 試做診斷數值與實際判定一致；完成／離開時 JSON 匯出成功、取消、失敗及丟棄流程。
- [ ] 修改或刪除鬧鐘保留已生效限制及任務；將鬧鐘切為停用時，只取消該鬧鐘的未完成任務、追加提醒、首頁下一個鬧鐘及生效限制，不影響其他鬧鐘。
- [ ] 有生效 App 限制時長按 30 秒或使用點按＋確認的安全備援；否則長按 3 秒。確認緊急解除後清除目前限制，保留未來排程。系統鬧鐘插入時仍能進入備援確認。
- [ ] 撤權、重啟、App Group 檔案不可讀、寫入失敗、平台排程部分失敗不誤報成功。
- [ ] 至少 2 晚真正跨夜測試，記錄裝置、OS、預定／觀察時間、結果及影片同意。

## 介面與支援

- [ ] 二十語言母語校閱、完整頁面、RTL、VoiceOver、最大 Dynamic Type、淺深色。
- [ ] 正式回饋端點端到端、失敗草稿、重試不重複、缺少 ok:true 不顯示成功。
- [ ] 真正 App Store 評論頁、公開隱私政策與支援頁。
- [ ] 歷史刪改、300 秒邊界、完整重設、權限修復入口與不誤導文案。

## 真機記錄格式

每一案例記錄：Build／commit、裝置及 OS、時區、權限、設定、操作步驟、預期、實際、證據位置、缺陷 ID、複測結果。相機影像只可使用參與者明確同意的測試資料，不加入 Git。

2026-10-23 局部複測：iPhone 13 的 Build 18 曾顯示限制中，但使用者實測第三方 App 沒有遮罩。Build 19 安裝後，使用者確認第三方 App 出現 Okiru 遮罩；Build 20 加入首次共用檔案缺失處理並已安裝、啟動。使用者關閉／重開 Okiru 後，再確認首頁限制狀態與第三方 App 遮罩都正常。其後僅修正了版本號產生方式，並重新安裝真正標示為 Build 20 的 App；尚未對這個重新打包的版本重做遮罩測試。`devicectl` 的 App Group 檔案清單沒有列出 `restrictions-v1.json`，與使用者的遮罩實測不一致；此項檔案可見性仍待查明，不能只以首頁文案作為驗收證據。Build 20 的 30 秒緊急解除亦待真機長按測試。

2026-10-29 安全缺陷：使用者回報早晨進入相機任務後出現「系統未保留所有要求的提醒」警告，隨即回到 Home；追加鬧鐘又使 30 秒長按緊急解除無法完成。Build 22 將任務／限制期間的提醒核對錯誤改為非阻斷訊息，避免 Root 與 Challenge 同時呈現警告，並加入點按＋確認的緊急解除備援。40 項核心測試通過；模擬器 UI 回歸測試證實模擬提醒核對失敗不會關閉任務畫面。Build 22 已安裝 iPhone 13；使用者確認能停留在任務畫面，且點按安全備援能開啟確認視窗。尚未確認按下最終解除後限制確實清除，也尚未以真實追加鬧鐘重現及複測；送審前仍須完成這兩項驗證。
