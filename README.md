# Wilds MC 26.3 — install bundle

Scratch distribution for a Minecraft **26.3** server (Paper + EduGeyser:
Java, Bedrock and Minecraft Education). No secrets, no `.env`, no world data.
Built from the Wilds source tree; `install.sh` is self-contained.

## Install (terminal only)

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/Python-Coderss/wilds-mc-bundle/main/install.sh
curl -fsSLo wilds-mc-26.3.zip https://raw.githubusercontent.com/Python-Coderss/wilds-mc-bundle/main/wilds-mc-26.3.zip
sudo bash install.sh wilds-mc-26.3.zip
```

Afterwards: `sudo nano /opt/wilds/.env` (PLAYIT_SECRET etc.), then
`sudo bash /opt/wilds/install.sh restart`.

Controls: `sudo bash /opt/wilds/install.sh start|stop|restart|status`.
