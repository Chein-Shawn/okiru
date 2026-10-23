# Okiru feedback backend

`Code.js` 是獨立 Google Apps Script Web App。`appsscript.json` 為 V8 設定。未部署，App 的 `Config/Services.json` 端點保持空白；不可聲稱已能收件。

## 部署

1. 建立 Okiru 專屬且非公開的 Google Sheet，欄位由 Code.js 的 HEADERS 定義。不要使用聲海正式資料表。
2. 新增 Apps Script 專案，放入 Code.js 與 manifest。Script Properties 設定 `SPREADSHEET_ID`。
3. 用預定收件的 Google 帳號檢查並授權所需試算表範圍；這可能授予腳本讀寫該帳號可存取的 Sheets，必須由帳號持有人確認。
4. 部署為 Web App、以擁有者執行、允許匿名提交；只公開收件端點，不公開試算表。匿名端點會收到垃圾提交，需監看 Apps Script 配額與垃圾資料。
5. 把正式 `/exec` HTTPS URL 填進 `Config/Services.json`。GET health 不能代替 POST 收件測試。
6. POST 有效表單，確認 `ok:true`、相同小寫 submissionID、表中一列；同 ID 重試不新增列，修改內容但沿用 ID 回 `id_conflict`。
7. 測试缺欄、超長、公式字首、非法 email、服務失效、權限失效；App 必須保留草稿且不顯示成功。

目前 Google Drive 外掛未安裝，依試算表技能要求的原生 Sheet 匯入流程尚未完成。此檔提供部署準備，不代表已取得 Google 讀寫授權。

## 防護

欄位白名單、長度限制、20 秒客戶端間隔、腳本鎖、穩定 ID／內容雜湊去重、試算表公式字首轉義、全域每分鐘 60 件保護。不是驗證身分或完整防濫用系統，沒有秘密硬編碼在 App。

伺服器使用 Unicode code point，前端使用相同的 Unicode scalar 計數規則。配額、重試、Google 回應重新導向及匿名部署權限需在正式端點實測。

不接收相機、聲音、完整鬧鐘歷史、廣告 ID、裝置 ID 或位置。Email 選填，因此提交內容可能與 email 連結；App Privacy 標示不能宣稱所有回饋不可連結個人。

```sh
node --test backend/feedback.test.cjs
```
