# 發佈手冊與申請草稿

2026-10-05 開發中：Build 10 已通過 36 項核心測試、模擬器編譯與簽署 iPhoneOS build。使用者的 Build 9 診斷檔證實十下只計入一下，Build 10 已依實測數值修正；裝置目前 unavailable，尚未安裝或取得修正後真人驗收。既有審查影片與 Build 8 不可直接當作新功能的證據。

狀態：App Store Connect 已建立 Apple ID `6814670275`；Family Controls Distribution 已提交並待 Apple 審查。Okiru 1.0.0 build 1 已成功上傳、完成處理及出口合規，狀態為「準備提交」，但尚未加入 App Review 或送審。以下供開發者確認後使用，不代表 Apple 已接受任何功能或權限。

已登記的 Apple Developer 設定（2026-09-22）：

- Team ID：`3NFD3KU8Q8`
- 主 App：`com.shawn.okiru`
- Device Activity Monitor：`com.shawn.okiru.OkiruMonitor`
- Shield Configuration：`com.shawn.okiru.OkiruShield`
- Shield Action：`com.shawn.okiru.OkiruShieldAction`
- App Group：`group.com.shawn.okiru`（已關聯四個 App ID）

## 發佈前置條件

1. Apple Developer Team ID、正式 Bundle ID、App Group 與 App Store Connect 紀錄已建立，Apple 服務登入亦已確認；實體 iPhone 已連接、配對及啟用 Developer Mode。Release build、archive、App Store 匯出、build 1 上傳與實機安裝／啟動均已成功；仍須完成裝置上的權限與功能操作證據。
2. 主 App、Monitor、Shield、Shield Action 的識別碼、App Group、Family Controls 與 provisioning 逐一核對；確認哪些 target 必須取得發佈授權，保存 Apple 回覆。
3. 完成 `ACCEPTANCE.md` 的真機矩陣、辨識樣本與兩晚跨夜。模擬器、unsigned device build 均不等於真機驗證。
4. 專用回饋 Sheet 與 Apps Script 正式部署；填 `Config/Services.json`，驗證第一次、重試、離線、拒收與失敗草稿。
5. 上線正式隱私與支援網址，確認資料管理人、聯絡方式、回饋保存期限與刪除程序；二十語言由母語使用者校閱。
6. 完成 App Store Connect 名稱可用性、描述、截圖、年齡分級、隱私揭露與評論 ID。相機只前景處理、不保存、不上傳；使用者主動送出的文字及選填 Email 是不同資料流，不能宣稱完全沒有收集資料。
7. 每個門檻都在 `Config/ReleaseEvidence.json` 填入真正證據位置、版本與結果，再執行 `python3 tools/release_check.py`。程式檢查不會替代人工確認。

## Family Controls 申請說明草稿

Okiru is an individual self-discipline alarm app. Users explicitly authorize Screen Time and select applications that remain available. Other applications and supported websites are shielded through ManagedSettings and DeviceActivity; users can additionally select Safari for direct shielding. Each restriction starts at its configured time and is released after its linked push-up challenge and the selected 15–120 minute delay. Overlapping restrictions retain the intersection of allowed applications. A clearly accessible emergency release removes all currently active Okiru restrictions; future schedules remain unchanged. Users can revoke authorization or uninstall the app. We do not claim parental supervision, blocking of every system app, or unbypassable device control.

The main app configures schedules and policies. The Device Activity Monitor applies time-based policies from an App Group store. Shield Configuration explains the restriction and directs users back to Okiru. Shield Action closes the shield action without forcing another app to open. All shared writes are coordinated; no camera images or app-usage history are uploaded. Please review the requested distribution entitlement for the main app and the relevant extensions.

2026-09-22 已由帳號持有人確認條款並提交 Family Controls Distribution 申請，Apple 顯示將審查並另行通知。待完成：取得 Distribution 核准；補聯絡人、實機操作影片及隱私網址。申請入口與要求送出前重新查核：[Apple Family Controls](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)。不要把「已提交」當成「已核准」。

## App Review 操作備註草稿

新 build 的精簡英文說明（只有在實際附上相符的真機影片後，才加入最後一句）：

> Okiru is a free alarm app that starts your day with a few push-ups. Its optional Screen Time restriction helps users avoid scrolling before sleep.
>
> No login, account creation, user-generated content, payments, subscriptions, ads, sample files, or demo credentials are required.
>
> Setup: launch Okiru, create a near-term one-time alarm in the Alarm tab, and grant Notifications and Camera permission. When the alarm occurs, open Okiru and complete the on-device push-up challenge. Alarm and history data stay on the device.
>
> Core functionality uses Apple frameworks only: AVFoundation and Vision for on-device pose analysis; AlarmKit on supported iOS 26+ devices or local notifications on iOS 17/18; and optional Family Controls/ManagedSettings for restrictions on apps and websites supported by iOS. No cloud AI, authentication, payments, analytics, or external data provider is required for core functionality.
>
> A physical-device screen recording showing launch, alarm setup, the challenge, completed repetitions, and history completion is attached.

Do not claim that every system app can be blocked. A direct Safari shield requires the reviewer to choose Safari in the additional blocked-app picker. The selected number of push-ups can vary from 5 to 100; practice remains ten. The video and review note must describe the **same uploaded build**.

- 無須帳號、無付費或廣告。Home 顯示每日基準鬧鐘結果；完成時間代表任務完成，非感測到的離床時間。
- 在 Alarm 新增近期單次鬧鐘並授權。iOS 26+ 使用 AlarmKit；iOS 17/18 使用本機通知。有限追加通知受通知設定、靜音與專注影響。系統 Stop 或滑掉不算任務完成。
- 進入任務後將手機固定，前鏡頭從側前方拍到上半身。完整撐起→下壓→撐起，依鬧鐘設定完成 5–100 下。5–45 下五分鐘、50–100 下十分鐘從原定響鈴開始；相機只在前景運作。試做固定十下，不寫正式統計，可自願匯出不含影像的判定 JSON。
- 授權 Screen Time、選擇允許 App，以及需要額外直接封鎖的 Safari 或網站；App 無法保證所有系統 App 都可遮罩。限制從設定時間開始，任務完成後再等所選延遲，由 Monitor 在背景嘗試解除；iOS 回呼時間不保證精確到秒。重疊限制需各自滿足。
- 主 App 有生效的 App 限制時，緊急解除需長按三十秒再確認；只有起床任務而無生效限制時為三秒。解除會另外記錄，並保留未來排程。使用者也可撤銷系統授權。
- 測試響鈴是五秒後的一般通知測試，不代表完整 AlarmKit 或跨夜能力驗收。

## 隱私政策／支援上線內容（待營運者確認）

政策需清楚列出：本機鬧鐘／歷史、Screen Time opaque tokens、前景即時相機處理、不保存影像、無追蹤或廣告、使用者主動提交的分類／摘要／詳情／選填 Email／版本／系統／語言、Google Apps Script 與 Sheets 收件、存取權限、保存期限與刪除請求方式。不可在未確認前編造公司名稱、支援 Email、保存期限或資料地區。

支援頁需提供：前鏡頭擺放圖解、通知與 AlarmKit 差異、權限修復、緊急解除、撤銷 Screen Time 授權、刪除歷史／完整重設說明、隱私聯絡入口。運動不適者應使用緊急解除；不得強迫使用者冒身體風險完成任務。

## 送審實際操作

由已授權帳號完成簽署、Archive、Validate、TestFlight 外部／內部測試，再交付審查。重核 [Apple 上傳要求](https://developer.apple.com/news/upcoming-requirements/)、隱私 manifest 與當時 SDK 要求。不得把本機 build 成功或空白的證據清單視為可發佈。
