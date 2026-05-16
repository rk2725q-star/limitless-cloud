## Limitless Cloud Backend

A FastAPI + Telethon backend for the Limitless Cloud Flutter app.

### Deploy to Railway (Free - 1 minute)

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template)

1. Go to [railway.app](https://railway.app) → sign up free with GitHub
2. Click **New Project → Deploy from GitHub repo**
3. Select this repo → Railway auto-detects the Dockerfile
4. After deploy, copy the **public URL** (e.g. `https://limitless-cloud.up.railway.app`)
5. In the Flutter app → Settings → paste that URL

### Local Development

```bash
pip install -r requirements.txt
python main.py
```

Server runs at `http://localhost:8000`
