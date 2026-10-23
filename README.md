# Okiru

原生 iPhone 起床自律 App。SwiftUI、iOS 17+、無帳號／廣告／訂閱；資料保存在本機，前鏡頭影像不錄製或上傳。

目前是開發版本；可建置不代表背景響鈴、真機計次或 App Store 審查已完成驗收。

## 開啟與建置

在 Xcode 開啟 `Okiru.xcodeproj`，選擇 `Okiru` scheme 與 iPhone 模擬器。專案由內附 Python 標準函式庫腳本產生，不需要 XcodeGen、CocoaPods 或第三方 SDK。

```sh
python3 tools/generate_project.py
python3 tools/validate_localizations.py
swift test --scratch-path work/swift-build
node --test backend/feedback.test.cjs
xcodebuild -project Okiru.xcodeproj -scheme Okiru \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build
```

UI 測試：把 destination 換成 `platform=iOS Simulator,id=<本機裝置 UUID>`，執行 `test`，加上 `ONLY_ACTIVE_ARCH=YES`。不要同時對同一個 DerivedData 執行兩個建置。

目前使用 Xcode 27 建置，deployment target 為 iOS 17。AlarmKit 呼叫有 26.0 與 26.1+ 分支。iOS 17 的實際執行仍未驗證；18.3.1 與 26.5 的模擬器導覽測試已通過。

## 目前內容

- Home 七日狀態、下一次鬧鐘、待完成任務、限制狀態、History 及每日基準統計。
- 單次／指定星期鬧鐘 CRUD、六種內建鈴聲、試聽與通知測試。鬧鐘已響且任務未完成時，不能透過停用、編輯、刪除或重設取消當次任務；完成或緊急解除後可再修改排程。
- iOS 26+ AlarmKit、舊版本機通知；有限追加提醒及實際排程核對。AlarmKit 與一般通知的聲音能力不同；三秒間隔是候選排程，不保證每次都響或準時送達。
- AVFoundation 前鏡頭、Vision 關節、鏡像骨架、完整上下動作狀態機；每個鬧鐘可設 5–100 下。正式任務在前景以 App 內播放器循環播放鈴聲。
- Family Controls 個人授權與選取器、共用政策、Device Activity／Shield／Shield Action 擴充套件、重疊例外交集與緊急解除。
- SwiftData 儲存、保留歷史快照、共享檔案協調與原子更新。
- 二十語言各 160 個字串與權限用途；完整性檢查無英文 fallback，仍需母語校閱。
- 原生回饋草稿、失敗保留與明確成功確認；Apps Script 伺服器與離線測試。正式端點尚未部署。

以上是實作狀態，不代表真機響鈴、辨識正確率或 Screen Time 行為已通過驗收。從圖示重新開啟 App 也會優先呈現最早到期且未解除的任務；iOS 仍允許使用者停止系統鬧鐘、關閉 App 或撤銷權限，Okiru 不宣稱不可繞過。

## 真機簽署

將 `Config/Local.example.xcconfig` 複製為 `Config/Local.xcconfig`，填入使用者確認的 Team ID、Bundle ID 前綴及 App Group。範例識別碼 `com.shawn.okiru` 尚未代表已註冊或可發佈。

主 App 和三個擴充套件需同一 Team、相同 App Group，且各自具备適當 Family Controls capability／provisioning。不要使用未核准的權限或假造 Team ID。正式 Family Controls 發佈權限申請與 Apple 回覆須另存驗收證據。

## 導覽

- `docs/ARCHITECTURE.md`：模組、生命週期及資料一致性。
- `docs/ACCEPTANCE.md`：實際測試與真機矩陣。
- `docs/RELEASE.md`：簽署、權限申請草稿、送審門檻。
- `backend/README.md`：回饋部署、權限與安全限制。
- `Resources/Translations/`：語言來源；文字檔順序對應 `Resources/translations.json` 的英語 key 順序，新增 key 必須同步所有語言。

## 授權與重要限制

程式碼採 [PolyForm Noncommercial 1.0.0](LICENSE.md)：可查看與依條款作非商業使用，商業用途請聯繫 support@vocaldive.com。這是 source-available，不是標準開源。鈴聲與圖示另有[媒體授權說明](MEDIA-LICENSE.md)，不自動套用程式碼授權。

不能承諾背景每五秒提醒、無限響鈴、禁止系統停止、不可撤銷的鎖定，或將任務完成時間稱為真正離床時間。通知被滑掉不是成功。追加提醒不繼承 AlarmKit 的靜音／專注穿透能力。

App Store ID、正式支援頁與隱私政策已配置；正式回饋端點仍待完成 Google 授權與端到端測試。`python3 tools/release_check.py` 應在缺少回饋端點、外部核准或真機證據時回報 NOT READY，不能為了送審自行把門檻打勾。
