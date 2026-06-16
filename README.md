# 🚀 CredsHunter Elite 💀

Automated web asset discovery & sensitive data hunter using Katana.

---

## ⚡ Features

- Deep crawling (JS + Headless + XHR)
- Endpoint discovery (JS, XHR, regex)
- Parameter mining (`?id=`, `?token=`)
- Sensitive data extraction (API Key, JWT, Token)
- Clean filename (no hash)
- Exclude domain support (`-e exclude.txt`)
- High-value endpoint filtering
- Request list generator (Burp / ffuf ready)

---

## 📦 Requirements

- katana
- jq
- curl
- chromium (for headless mode)

---

## ▶️ Usage

### Basic
```bash
./credshunter.sh -i targets.txt
```
### Advanced
```bash
./credshunter.sh -i targets.txt -e exclude.txt -c 'session=42'
```
