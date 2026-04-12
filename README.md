# AirBoneRadio
AirBoneRadio is a lightweight, complete self-hosted internet radio management system designed to replicate core features of larger platforms while maintaining minimal resource usage and sleek modular design intended for 24/7 AutoDJ streaming with Simple, beautiful Neon Orange and Lime Green web-based interface which allows you to Broadcast your music to the world with AutoDJ, playlists, and real-time streaming via the control panel Optimized for low-resource VPS. 

No heavy frameworks - No built-in transcoding engine - No clustering 

## Features

- **Media Library** - Upload and manage your music collection (MP3, OGG, FLAC, WAV, M4A)
- **Playlist Management** - Create, edit, and organize playlists
- **AutoDJ** - Automatic playback with playlist rotation
- **Multiple Broadcast Formats** - MP3, AAC, OGG Vorbis
- **Configurable Bitrate** - 64 to 320 kbps options
- **Web Player** - Built-in audio player with live visualization
- **Listener Statistics** - Real-time listener count
- **Single-Command Installation** - `./setup.sh` installs everything

## Requirements

- Ubuntu 20.04, 22.04, or 24.04
- Debian 9, 10, 11, 12, or 13
- Root access (sudo)

## Quick Start

```bash
# Download the installer
wget https://github.com/tchovi/AirBoneRadio.git

# Make it executable
chmod +x setup.sh

# Run the installer
sudo ./setup.sh
```

After installation, access:
- **Control Panel:** http://your-server/radio/
- **Stream URL:** http://your-server:8000/stream

## Default Credentials

- **Username:** admin
- **Password:** (randomly generated during installation, see `/var/log/airbone-install.log`)

## Installation Details

### What Gets Installed

| Service | Purpose | Port |
|---------|---------|------|
| Lighttpd | Web server | 80 |
| PHP-FPM | PHP processing | Socket |
| Icecast2 | Streaming server | 8000 |
| Liquidsoap | AutoDJ / Audio processing | Background |

### Installed Packages

```
lighttpd, php-fpm, php-sqlite3, php-xml, php-json,
sqlite3, icecast2, liquidsoap, ffmpeg, curl, wget,
icecast2, liquidsoap, ffmpeg, fdkaac, liquidsoap-plugin-fdkaac
```

## Usage

### Uploading Music

1. Log in to the control panel
2. Go to **Media Library**
3. Click **Upload Music**
4. Select audio files (up to 20MB each)
5. Stream starts automatically after upload

### Creating Playlists

1. Go to **Playlists**
2. Click **Create Playlist**
3. Add songs from your library
4. Export as .m3u if needed

### Changing Broadcast Settings

1. Go to **Settings**
2. Select your preferred **Broadcast Format**
3. Choose **Bitrate**
4. Click **Save Settings**
5. Restart AutoDJ from the Dashboard

### Supported Formats

| Format | Extension | Description |
|--------|----------|-------------|
| MP3 | .mp3 | Most compatible, recommended |
| AAC | .aac | Better quality at lower bitrates |
| OGG | .ogg | Open source, good quality |

### Bitrate Options

- 64 kbps - Low bandwidth
- 96 kbps - Standard
- 128 kbps - **Recommended**
- 192 kbps - High quality
- 256 kbps - Very high
- 320 kbps - Maximum

## Control Scripts

```bash
# Start AutoDJ
/var/www/airbone/scripts/start.sh

# Stop AutoDJ
/var/www/airbone/scripts/stop.sh

# Restart AutoDJ
/var/www/airbone/scripts/restart.sh
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/radio/api/start.php` | POST | Start AutoDJ |
| `/radio/api/stop.php` | POST | Stop AutoDJ |
| `/radio/api/skip.php` | POST | Skip current track |
| `/radio/api/nowplaying.php` | GET | Get current track info |
| `/radio/api/listeners.php` | GET | Get listener count |
| `/radio/api/upload.php` | POST | Upload audio files |

## Directory Structure

```
/var/www/airbone/
├── app/
│   ├── index.php         # Dashboard
│   ├── player.php        # Web Player
│   ├── library.php       # Media Library
│   ├── playlists.php     # Playlist Management
│   ├── settings.php      # Settings
│   ├── login.php         # Login
│   ├── logout.php        # Logout
│   ├── api/              # REST API
│   │   ├── start.php
│   │   ├── stop.php
│   │   ├── skip.php
│   │   ├── nowplaying.php
│   │   ├── listeners.php
│   │   └── upload.php
│   ├── css/
│   │   └── style.css
│   ├── js/
│   │   └── main.js
│   └── includes/
│       ├── config.php
│       └── auth.php
├── autodj.liq            # Liquidsoap script
├── airbone.db            # SQLite database
├── music/                # Uploaded music
├── jingles/              # Jingles folder
├── playlists/            # Playlist files
├── scripts/
│   ├── start.sh
│   ├── stop.sh
│   └── restart.sh
└── log/                  # Log files
```

## Configuration Files

- **Icecast:** `/etc/icecast2/icecast.xml`
- **Lighttpd:** `/etc/lighttpd/lighttpd.conf`
- **PHP:** `/etc/php/*/fpm/php.ini`
- **AutoDJ Log:** `/var/log/airbone/autodj.log`
- **Icecast Logs:** `/var/log/icecast2/`

## Theme

AirBoneRadio features a custom Neon Orange and Lime Green theme:

- **Primary Background:** Slate Gray (#2c3e50)
- **Neon Orange:** #ff6600 (buttons, highlights)
- **Lime Green:** #32cd32 (text, active states)
- **Rounded corners:** 16px border radius

## Troubleshooting

### Stream not playing?

```bash
# Check if services are running
ps aux | grep lighttpd
ps aux | grep icecast2
ps aux | grep liquidsoap

# Restart services
sudo systemctl restart lighttpd
sudo systemctl restart icecast2

# Check AutoDJ log
sudo tail -20 /var/log/airbone/autodj.log
```

### Upload failing?

```bash
# Check PHP upload limits
php -i | grep upload_max_filesize

# Fix if needed (20MB)
sudo sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/' /etc/php/*/fpm/php.ini
sudo systemctl restart php*-fpm
```

### Reset admin password

```bash
sudo sqlite3 /var/www/airbone/airbone.db \
  "UPDATE users SET password='\$2y\$10\$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi' WHERE username='admin';"
```

Then login with: **admin / password**

## Uninstall

```bash
# Stop all services
sudo systemctl stop lighttpd icecast2
sudo pkill -f liquidsoap

# Remove files
sudo rm -rf /var/www/airbone
sudo rm -f /etc/lighttpd/conf-enabled/15-airbone.conf

# Remove packages (optional)
sudo apt remove --purge lighttpd php-fpm icecast2 liquidsoap sqlite3
```

## License

This project is open source and available under the MIT License.

## Support

For issues and feature requests, please use the GitHub Issues page.

---

**Made with ❤️ for internet radio broadcasters** Enjoy!
