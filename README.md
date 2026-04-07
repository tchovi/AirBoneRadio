# AirBoneRadio
AirBoneRadio is a lightweight, complete self-hosted internet radio management system designed to replicate core features of larger platforms while maintaining minimal resource usage and sleek modular design intended for 24/7 AutoDJ streaming with Simple web-based control panel Optimized for low-resource VPS.

No heavy frameworks - No built-in transcoding engine - No clustering 

What's under the hood?
-   Minimalist design
-   Fast loading

Core Features

-   Media Library (upload/store songs)
-   Playlist Management (.m3u export)
-   AutoDJ Control (start/stop/skip)
-   Icecast Streaming
-   Now Playing & Listener Stats
-   Basic Scheduling (cron)
-   User Authentication
  
AirBoneRadio - Software & Services
-   Lighttpd: Web server for control panel	80
-   PHP-FPM: PHP processing for web app
-   Icecast2: Streaming server 8000
-   Liquidsoap: AutoDJ / Audio processing	Background
  
How it works now:

Upload songs → Stream auto-starts with your selected format
Go to Settings → Change format/bitrate → Save
Click "Start" on Dashboard → Stream uses new settings
Default: MP3 @ 128 kbps

How to install 

-   sudo apt update
-   sudo apt install git -y
-   git clone https://github.com/tchovi/AirBoneRadio.git
-   cd AirBoneRadio
-   chmod +x setup.sh
-   sudo ./setup.sh

Access Points
Control Panel: http://localhost/radio/
Stream URL: http://localhost:8000/stream
Icecast Admin: http://localhost:8000/admin
Enjoy!
