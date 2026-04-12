#!/bin/bash

set -e

RADIO_DIR="/var/www/airbone"
LOG_FILE="/var/log/airbone-install.log"
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 12)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Please run as root (use sudo)"
    fi
}

detect_os() {
    log "Detecting OS..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        error_exit "Cannot detect OS. Supports Ubuntu 20,22,24 and Debian 9,10,11,12,13"
    fi

    SUPPORTED=false
    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in
                20.04|22.04|24.04) SUPPORTED=true ;;
            esac
            ;;
        debian)
            case "$OS_VERSION" in
                9|10|11|12|13) SUPPORTED=true ;;
            esac
            ;;
    esac

    if [ "$SUPPORTED" = false ]; then
        error_exit "Unsupported OS: $OS_ID $VERSION_ID"
    fi
    log "Detected: $OS_ID $VERSION_ID"
}

install_dependencies() {
    log "Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update >> "$LOG_FILE" 2>&1

    local packages=(
        "lighttpd"
        "php-fpm"
        "php-sqlite3"
        "php-xml"
        "php-json"
        "php-cli"
        "php-common"
        "sqlite3"
        "icecast2"
        "ffmpeg"
        "fdkaac"
        "curl"
        "wget"
        "apache2-utils"
        "net-tools"
        "bsdutils"
    )

    # php-common includes posix extension; install php-posix if available separately
    apt-get install -y php-posix >> "$LOG_FILE" 2>&1 || log "Note: php-posix not a separate package (included in php-common)"

    for pkg in "${packages[@]}"; do
        log "Installing $pkg..."
        apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 || log "Warning: Failed to install $pkg"
    done

    # Install Liquidsoap - try 1.x compatible version, then any available
    log "Installing Liquidsoap..."
    LIQUIDSOAP_OK=false

    # Try exact version first (|| true prevents set -e from aborting)
    apt-get install -y liquidsoap=1.1.4-* >> "$LOG_FILE" 2>&1 && LIQUIDSOAP_OK=true || true

    # Try any available version
    if [ "$LIQUIDSOAP_OK" = false ]; then
        apt-get install -y liquidsoap >> "$LOG_FILE" 2>&1 || true
        if command -v liquidsoap > /dev/null 2>&1; then
            INSTALLED_VERSION=$(liquidsoap --version 2>/dev/null | head -1 || echo "unknown")
            log "Installed Liquidsoap version: $INSTALLED_VERSION"
            # Detect major version: 1.x uses mode="randomize", 2.x uses different syntax
            LIQ_MAJOR=$(liquidsoap --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
            if [ "$LIQ_MAJOR" = "1" ]; then
                LIQUIDSOAP_OK=true
                log "Liquidsoap 1.x detected - syntax compatible"
            elif [ "$LIQ_MAJOR" = "2" ]; then
                log "Liquidsoap 2.x detected - will generate 2.x compatible scripts"
                LIQUIDSOAP_OK=true
                LIQUIDSOAP_V2=true
            else
                log "Warning: Unknown Liquidsoap version, assuming 1.x syntax"
                LIQUIDSOAP_OK=true
            fi
        fi
    fi

    if [ "$LIQUIDSOAP_OK" = false ]; then
        error_exit "Failed to install Liquidsoap. Install manually: apt-get install liquidsoap"
    fi

    # Install Liquidsoap codec plugins (needed for MP3/OGG encoding/decoding)
    log "Installing Liquidsoap codec plugins..."
    for plugin in liquidsoap-plugin-lame liquidsoap-plugin-mad liquidsoap-plugin-vorbis \
                  liquidsoap-plugin-flac liquidsoap-plugin-taglib liquidsoap-plugin-faad \
                  liquidsoap-plugin-ogg liquidsoap-plugin-samplerate liquidsoap-plugin-ffmpeg \
                  liquidsoap-plugin-fdkaac; do
        apt-get install -y "$plugin" >> "$LOG_FILE" 2>&1 || true
    done
    log "Liquidsoap plugins installed (or already built-in)"

    log "Dependencies installed"
}

create_directory_structure() {
    log "Creating directory structure..."
    mkdir -p "$RADIO_DIR"/{music,jingles,playlists,scripts,log}
    mkdir -p "$RADIO_DIR/app"/{api,includes,css,js}
    mkdir -p /var/run/airbone /var/log/airbone
    chmod -R 755 "$RADIO_DIR"
    log "Directory structure created"
}

setup_icecast() {
    log "Configuring Icecast2..."
    
    # Create icecast2 group and user if they don't exist
    if ! getent group icecast2 > /dev/null 2>&1; then
        log "Creating icecast2 group..."
        groupadd icecast2 2>/dev/null || true
    fi
    
    if ! id icecast2 > /dev/null 2>&1; then
        log "Creating icecast2 user..."
        useradd -r -g icecast2 -s /bin/false -d /nonexistent icecast2 2>/dev/null || true
    fi
    
    cat > /etc/icecast2/icecast.xml << 'ICECASTEOF'
<icecast>
    <limits>
        <clients>100</clients>
        <sources>10</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
    </limits>
    <authentication>
        <source-password>airbone_source_pass</source-password>
        <relay-password>airbone_relay_pass</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>airbone_admin_pass</admin-password>
    </authentication>
    <hostname>localhost</hostname>
    <listen-socket>
        <port>8000</port>
    </listen-socket>
    <mount>
        <mount-name>/stream</mount-name>
        <max-listeners>100</max-listeners>
        <fallback-mount>/nobody.mp3</fallback-mount>
        <fallback-override>1</fallback-override>
        <public>1</public>
    </mount>
    <fileserve>1</fileserve>
    <paths>
        <basedir>/usr/share/icecast2</basedir>
        <logdir>/var/log/icecast2</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
    </paths>
    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>4</loglevel>
    </logging>
    <security>
        <chroot>0</chroot>
        <changeowner>
            <user>icecast2</user>
            <group>icecast2</group>
        </changeowner>
    </security>
</icecast>
ICECASTEOF

    # Enable Icecast
    sed -i 's/ENABLE=false/ENABLE=true/' /etc/default/icecast2 2>/dev/null || true
    
    # Create fallback file
    mkdir -p /usr/share/icecast2/web
    touch /usr/share/icecast2/web/nobody.mp3
    
    # Create log directory
    mkdir -p /var/log/icecast2
    chown -R icecast2:icecast2 /var/log/icecast2 2>/dev/null || chown -R root:root /var/log/icecast2
    
    log "Icecast configured"
}

setup_lighttpd() {
    log "Configuring Lighttpd with PHP-FPM..."
    
    # Start PHP-FPM first
    log "Starting PHP-FPM..."
    for svc in php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
        if systemctl list-unit-files | grep -q "$svc"; then
            systemctl enable $svc 2>/dev/null || true
            systemctl start $svc 2>/dev/null || true
        fi
    done
    service php*-fpm start 2>/dev/null || true
    sleep 3
    
    # Detect PHP-FPM socket
    PHP_SOCKET=""
    for phpver in 8.3 8.2 8.1 8.0 7.4; do
        if [ -S "/run/php/php${phpver}-fpm.sock" ]; then
            PHP_SOCKET="/run/php/php${phpver}-fpm.sock"
            break
        fi
        if [ -S "/var/run/php/php${phpver}-fpm.sock" ]; then
            PHP_SOCKET="/var/run/php/php${phpver}-fpm.sock"
            break
        fi
    done
    
    if [ -z "$PHP_SOCKET" ]; then
        log "Warning: No PHP-FPM socket found, will use default"
        PHP_SOCKET="/run/php/php8.3-fpm.sock"
    fi
    log "Using PHP socket: $PHP_SOCKET"
    
    # Remove ALL conflicting configs first
    log "Removing conflicting Lighttpd configs..."
    rm -f /etc/lighttpd/conf-enabled/90-upload.conf
    rm -f /etc/lighttpd/conf-enabled/15-fastcgi*.conf
    rm -f /etc/lighttpd/conf-enabled/10-fastcgi.conf
    rm -f /etc/lighttpd/conf-enabled/15-cgi.conf
    rm -f /etc/lighttpd/conf-enabled/20-fastcgi*.conf
    rm -f /etc/lighttpd/conf-enabled/10-php*.conf
    rm -f /etc/lighttpd/conf-enabled/15-php*.conf
    rm -f /etc/lighttpd/conf-enabled/99-unconfigured.conf 2>/dev/null || true
    
    # Create clean Lighttpd config
    # Check if mod_fastcgi is already loaded in main config to avoid duplicate module error
    log "Creating AirBone Lighttpd configuration..."
    FASTCGI_LOADED=false
    if grep -qE '^\s*server\.modules.*mod_fastcgi' /etc/lighttpd/lighttpd.conf 2>/dev/null; then
        FASTCGI_LOADED=true
        log "mod_fastcgi already in main config, skipping module load"
    fi

    if [ "$FASTCGI_LOADED" = true ]; then
        cat > /etc/lighttpd/conf-available/15-airbone.conf << CONFEOF
alias.url += (
    "/radio" => "${RADIO_DIR}/app",
    "/music" => "${RADIO_DIR}/music"
)

index-file.names += ("index.php")

fastcgi.server += ( ".php" => ((
    "socket" => "${PHP_SOCKET}",
    "broken-scriptfilename" => "enable",
    "check-local" => "disable"
)))
CONFEOF
    else
        cat > /etc/lighttpd/conf-available/15-airbone.conf << CONFEOF
server.modules += ( "mod_fastcgi" )

alias.url += (
    "/radio" => "${RADIO_DIR}/app",
    "/music" => "${RADIO_DIR}/music"
)

index-file.names += ("index.php")

fastcgi.server += ( ".php" => ((
    "socket" => "${PHP_SOCKET}",
    "broken-scriptfilename" => "enable",
    "check-local" => "disable"
)))
CONFEOF
    fi

    ln -sf /etc/lighttpd/conf-available/15-airbone.conf /etc/lighttpd/conf-enabled/15-airbone.conf
    
    # Fix socket permissions
    chown www-data:www-data "$PHP_SOCKET" 2>/dev/null || true
    chmod 660 "$PHP_SOCKET" 2>/dev/null || true
    
    log "Lighttpd configured"
}

setup_php_upload() {
    log "Configuring PHP upload settings (20MB max)..."
    
    # Find and update all PHP ini files
    for PHP_INI in $(find /etc/php -name "php.ini" 2>/dev/null); do
        log "Updating $PHP_INI..."
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/; s/^post_max_size.*/post_max_size = 25M/; s/^memory_limit.*/memory_limit = 128M/; s/^max_execution_time.*/max_execution_time = 300/; s/^max_input_time.*/max_input_time = 300/' "$PHP_INI" 2>/dev/null || true
    done
    
    # Also fix /etc/php.ini if exists
    if [ -f "/etc/php.ini" ]; then
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/; s/^post_max_size.*/post_max_size = 25M/' /etc/php.ini 2>/dev/null || true
    fi
    
    # Create upload directory
    mkdir -p /var/cache/lighttpd/uploads
    chmod 755 /var/cache/lighttpd/uploads
    
    log "PHP upload settings configured"
}

create_liquidsoap_script() {
    log "Creating Liquidsoap AutoDJ script..."

    if [ "$LIQUIDSOAP_V2" = true ]; then
        cat > "$RADIO_DIR/autodj.liq" << 'LIQEOF'
#!/usr/bin/liquidsoap
settings.log.file.set(true)
settings.log.file.path.set("/var/log/airbone/autodj.log")
settings.log.level.set(3)

music = playlist(mode="randomize", "/var/www/airbone/music")
radio = mksafe(music)

output.icecast(%mp3(bitrate=128),
  host="127.0.0.1",
  port=8000,
  password="airbone_source_pass",
  mount="/stream",
  radio)
LIQEOF
    else
        cat > "$RADIO_DIR/autodj.liq" << 'LIQEOF'
#!/usr/bin/liquidsoap
set("log.file",true)
set("log.file.path","/var/log/airbone/autodj.log")
set("log.level",3)

music = playlist(mode="randomize", reload=3600, "/var/www/airbone/music")
radio = mksafe(music)

output.icecast(%mp3(bitrate=128, samplerate=44100, stereo=true),
  host="127.0.0.1",
  port=8000,
  password="airbone_source_pass",
  mount="/stream",
  radio)
LIQEOF
    fi

    chmod 644 "$RADIO_DIR/autodj.liq"
    log "Liquidsoap script created"
}

setup_initial_user() {
    log "Setting up initial admin user..."
    
    # Generate password hash using PHP (reliable bcrypt compatible with password_verify)
    # Pass password via stdin to avoid shell quoting issues
    ADMIN_HASH=$(echo -n "$ADMIN_PASS" | php -r "echo password_hash(file_get_contents('php://stdin'), PASSWORD_DEFAULT);" 2>/dev/null)

    if [ -z "$ADMIN_HASH" ] || [ ${#ADMIN_HASH} -lt 20 ]; then
        log "PHP password_hash failed, trying htpasswd..."
        ADMIN_HASH=$(htpasswd -bnBC 10 "" "$ADMIN_PASS" 2>/dev/null | tr -d ':\n' | sed 's/^\$2y\$/\$2y\$/')
    fi

    if [ -z "$ADMIN_HASH" ] || [ ${#ADMIN_HASH} -lt 20 ]; then
        log "ERROR: Could not generate password hash. Install php-cli first."
        error_exit "Password hashing failed"
    fi
    
    # Initialize database
    sqlite3 "$RADIO_DIR/airbone.db" << DBSQL
CREATE TABLE IF NOT EXISTS songs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT UNIQUE NOT NULL,
    original_name TEXT NOT NULL,
    title TEXT,
    artist TEXT,
    duration INTEGER,
    uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    schedule_type TEXT DEFAULT 'general',
    schedule_value INTEGER DEFAULT 1,
    playback_order TEXT DEFAULT 'shuffled',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS playlist_songs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    playlist_id INTEGER NOT NULL,
    song_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

DELETE FROM users WHERE username = 'admin';
INSERT INTO users (username, password, role) VALUES ('admin', '$ADMIN_HASH', 'admin');

INSERT OR IGNORE INTO settings (key, value) VALUES ('stream_format', 'mp3');
INSERT OR IGNORE INTO settings (key, value) VALUES ('stream_bitrate', '128');
INSERT OR IGNORE INTO settings (key, value) VALUES ('station_name', 'AirBoneRadio');
INSERT OR IGNORE INTO settings (key, value) VALUES ('crossfade_seconds', '0.0');
INSERT OR IGNORE INTO settings (key, value) VALUES ('crossfade_enabled', '0');
DBSQL
    
    chmod 644 "$RADIO_DIR/airbone.db"
    log "Initial admin user created"
}

create_php_files() {
    log "Creating PHP files..."

    cat > "$RADIO_DIR/app/includes/config.php" << 'PHPEOF'
<?php
define('RADIO_DIR', '/var/www/airbone');
define('MUSIC_DIR', RADIO_DIR . '/music');
define('JINGLES_DIR', RADIO_DIR . '/jingles');
define('PLAYLISTS_DIR', RADIO_DIR . '/playlists');
define('DB_PATH', RADIO_DIR . '/airbone.db');
define('ICECAST_HOST', 'localhost');
define('ICECAST_PORT', 8000);
$config = [
    'stream_url' => 'http://' . ($_SERVER['SERVER_NAME'] ?? 'localhost') . ':8000/stream',
    'admin_email' => 'admin@localhost',
    'max_upload_size' => 20 * 1024 * 1024,
    'allowed_extensions' => ['mp3', 'ogg', 'flac', 'wav', 'm4a', 'aac']
];

// Auto-migrate: add playlist scheduling columns if missing
function migrateDatabase() {
    try {
        $db = new PDO('sqlite:' . DB_PATH);
        $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $cols = $db->query("PRAGMA table_info(playlists)")->fetchAll(PDO::FETCH_COLUMN, 1);
        if (!in_array('schedule_type', $cols)) {
            $db->exec("ALTER TABLE playlists ADD COLUMN schedule_type TEXT DEFAULT 'general'");
            $db->exec("ALTER TABLE playlists ADD COLUMN schedule_value INTEGER DEFAULT 1");
            $db->exec("ALTER TABLE playlists ADD COLUMN playback_order TEXT DEFAULT 'shuffled'");
        }
    } catch (Exception $e) { /* columns may already exist */ }
}
migrateDatabase();
PHPEOF

    cat > "$RADIO_DIR/app/includes/auth.php" << 'AUTHEOF'
<?php
session_start();
function is_logged_in() { return isset($_SESSION['user_id']); }
function require_login() { if (!is_logged_in()) { header('Location: login.php'); exit; } }
function login($username, $password) {
    $db = new PDO('sqlite:' . DB_PATH);
    $stmt = $db->prepare("SELECT * FROM users WHERE username = ?");
    $stmt->execute([$username]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($user && password_verify($password, $user['password'])) {
        $_SESSION['user_id'] = $user['id'];
        $_SESSION['username'] = $user['username'];
        $_SESSION['role'] = $user['role'];
        return true;
    }
    return false;
}
function logout() { session_destroy(); }
function generate_csrf() {
    if (empty($_SESSION['csrf_token'])) { $_SESSION['csrf_token'] = bin2hex(random_bytes(32)); }
    return $_SESSION['csrf_token'];
}
AUTHEOF

    cat > "$RADIO_DIR/app/includes/liquidsoap.php" << 'LIQHELPEOF'
<?php
function getLiquidsoapBinary() {
    foreach (['/usr/bin/liquidsoap', '/usr/local/bin/liquidsoap', 'liquidsoap'] as $candidate) {
        if ($candidate === 'liquidsoap') {
            $found = trim(@shell_exec('command -v liquidsoap 2>/dev/null') ?: '');
            if ($found !== '') return $found;
        } elseif (@is_executable($candidate)) {
            return $candidate;
        }
    }
    return 'liquidsoap';
}

/**
 * Generates a Liquidsoap script based on playlist configuration.
 * Handles both Liquidsoap 1.x and 2.x syntax.
 * Returns ['script' => string, 'format' => string, 'bitrate' => int]
 */
function generateLiquidsoapScript() {
    $db = new PDO('sqlite:' . DB_PATH);
    $settings = $db->query("SELECT * FROM settings")->fetchAll(PDO::FETCH_KEY_PAIR);
    $format = $settings['stream_format'] ?? 'mp3';
    $bitrate = (int)($settings['stream_bitrate'] ?? 128);
    $crossfadeRaw = $settings['crossfade_seconds'] ?? null;
    if ($crossfadeRaw === null) {
        $crossfadeSeconds = (($settings['crossfade_enabled'] ?? '0') === '1') ? 3.0 : 0.0;
    } else {
        $crossfadeSeconds = (float)$crossfadeRaw;
    }
    if ($crossfadeSeconds < 0) $crossfadeSeconds = 0;
    if ($crossfadeSeconds > 12.9) $crossfadeSeconds = 12.9;
    $crossfadeSeconds = round($crossfadeSeconds, 1);

    // Detect Liquidsoap version
    $liqBin = getLiquidsoapBinary();
    $liqVer = trim(@shell_exec($liqBin . " --version 2>/dev/null | head -1") ?: '');
    $isV2 = (strpos($liqVer, 'Liquidsoap 2') !== false);

    // Reload param: 1.x supports reload=N, 2.x does not
    $reloadParam = $isV2 ? '' : ', reload=3600';

    // Script header
    $s = "#!/usr/bin/liquidsoap\n";
    if ($isV2) {
        $s .= "settings.log.file.set(true)\n";
        $s .= "settings.log.file.path.set(\"/var/log/airbone/autodj.log\")\n";
        $s .= "settings.log.level.set(3)\n\n";
    } else {
        $s .= "set(\"log.file\",true)\n";
        $s .= "set(\"log.file.path\",\"/var/log/airbone/autodj.log\")\n";
        $s .= "set(\"log.level\",3)\n\n";
    }

    // Fallback: scan music directory (always available)
    $s .= "# Fallback: full music library\n";
    $s .= "music = playlist(mode=\"randomize\"{$reloadParam}, \"/var/www/airbone/music\")\n\n";

    // Get playlists that have at least one song
    $playlists = $db->query("
        SELECT p.*, COUNT(ps.id) as song_count
        FROM playlists p
        JOIN playlist_songs ps ON p.id = ps.playlist_id
        GROUP BY p.id
        HAVING song_count > 0
        ORDER BY p.id
    ")->fetchAll(PDO::FETCH_ASSOC);

    if (!empty($playlists)) {
        @mkdir('/var/www/airbone/playlists', 0755, true);

        $generalSources = [];
        $generalWeights = [];
        $onceSongsSources = [];

        foreach ($playlists as $pl) {
            $id = (int)$pl['id'];
            $type = $pl['schedule_type'] ?? 'general';
            $value = max(1, (int)($pl['schedule_value'] ?? 1));
            $order = $pl['playback_order'] ?? 'shuffled';
            if (!in_array($order, ['shuffled', 'random', 'sequential'], true)) {
                $order = 'shuffled';
            }

            // Map playback_order to Liquidsoap mode
            $mode = 'randomize';
            if ($order === 'sequential') {
                $mode = 'normal';
            } elseif ($order === 'random') {
                $mode = 'random';
            } elseif ($isV2) {
                $mode = 'random';
            }

            // Export M3U file
            $songs = $db->query("
                SELECT s.filename FROM playlist_songs ps
                JOIN songs s ON ps.song_id = s.id
                WHERE ps.playlist_id = {$id}
                ORDER BY ps.position
            ")->fetchAll(PDO::FETCH_COLUMN);

            $m3u = "#EXTM3U\n";
            foreach ($songs as $f) {
                $m3u .= "/var/www/airbone/music/{$f}\n";
            }
            @file_put_contents("/var/www/airbone/playlists/{$id}.m3u", $m3u);

            // Generate playlist source
            $s .= "p_{$id} = playlist(mode=\"{$mode}\"{$reloadParam}, \"/var/www/airbone/playlists/{$id}.m3u\")\n";

            // Categorize by schedule type
            switch ($type) {
                case 'once_per_x_songs':
                    $onceSongsSources[] = ['id' => $id, 'every' => $value];
                    break;
                case 'once_per_x_minutes':
                    // Approximate: assume avg song ~3.5 min
                    $songEquiv = max(1, round($value / 3.5));
                    $onceSongsSources[] = ['id' => $id, 'every' => $songEquiv];
                    break;
                default: // general
                    $generalSources[] = "p_{$id}";
                    $generalWeights[] = $value;
                    break;
            }
        }

        $s .= "\n";

        // Build main rotation from general playlists
        if (count($generalSources) > 1) {
            $s .= "# General rotation (weighted)\n";
            $s .= "main = rotate(weights=[" . implode(', ', $generalWeights) . "], [" . implode(', ', $generalSources) . "])\n";
        } elseif (count($generalSources) == 1) {
            $s .= "main = {$generalSources[0]}\n";
        } else {
            $s .= "main = music\n";
        }

        // Layer "once per X songs" playlists via weighted rotation
        foreach ($onceSongsSources as $ops) {
            $mainWeight = max(1, $ops['every'] - 1);
            $s .= "main = rotate(weights=[{$mainWeight}, 1], [main, p_{$ops['id']}])\n";
        }

        $s .= "radio = main\n";

        // Final fallback to music dir if all playlists fail
        $s .= "radio = fallback(track_sensitive=false, [radio, music])\n";
    } else {
        // No playlists configured - use music directory
        $s .= "radio = music\n";
    }

    if ($crossfadeSeconds > 0) {
        $cf = number_format($crossfadeSeconds, 1, '.', '');
        if ($isV2) {
            $s .= "radio = crossfade(fade_in={$cf}, fade_out={$cf}, radio)\n";
        } else {
            $s .= "radio = crossfade(start_next={$cf}, fade_in={$cf}, fade_out={$cf}, radio)\n";
        }
    }

    $s .= "radio = mksafe(radio)\n\n";

    // Output encoding
    if ($isV2) {
        if ($format == 'aac') { $s .= "output.icecast(%ffmpeg(format=\"adts\", %audio(codec=\"aac\", channels=2, samplerate=44100, b=\"{$bitrate}k\")),\n"; }
        elseif ($format == 'ogg') { $s .= "output.icecast(%vorbis(quality=0.5),\n"; }
        else { $format = 'mp3'; $s .= "output.icecast(%mp3(bitrate={$bitrate}),\n"; }
    } else {
        if ($format == 'aac') { $format = 'mp3'; $s .= "output.icecast(%mp3(bitrate={$bitrate}, samplerate=44100, stereo=true),\n"; }
        elseif ($format == 'ogg') { $s .= "output.icecast(%vorbis(quality=0.5),\n"; }
        else { $format = 'mp3'; $s .= "output.icecast(%mp3(bitrate={$bitrate}, samplerate=44100, stereo=true),\n"; }
    }
    $s .= "  host=\"127.0.0.1\",\n";
    $s .= "  port=8000,\n";
    $s .= "  password=\"airbone_source_pass\",\n";
    $s .= "  mount=\"/stream\",\n";
    $s .= "  radio)\n";

    return ['script' => $s, 'format' => strtoupper($format), 'bitrate' => $bitrate];
}

/**
 * Export a single playlist as M3U file to disk.
 */
function exportPlaylistM3U($playlistId) {
    $db = new PDO('sqlite:' . DB_PATH);
    $songs = $db->query("
        SELECT s.filename FROM playlist_songs ps
        JOIN songs s ON ps.song_id = s.id
        WHERE ps.playlist_id = " . (int)$playlistId . "
        ORDER BY ps.position
    ")->fetchAll(PDO::FETCH_COLUMN);

    @mkdir(PLAYLISTS_DIR, 0755, true);
    $path = PLAYLISTS_DIR . '/' . (int)$playlistId . '.m3u';

    if (empty($songs)) {
        @unlink($path);
        return;
    }

    $m3u = "#EXTM3U\n";
    foreach ($songs as $f) {
        $m3u .= MUSIC_DIR . "/{$f}\n";
    }
    @file_put_contents($path, $m3u);
}
LIQHELPEOF

    log "PHP files created"
}

create_pages() {
    log "Creating web pages..."

    cat > "$RADIO_DIR/app/login.php" << 'LOGINEOF'
<?php
require_once 'includes/config.php';
require_once 'includes/auth.php';
if (is_logged_in()) { header('Location: index.php'); exit; }
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = $_POST['username'] ?? '';
    $password = $_POST['password'] ?? '';
    if (login($username, $password)) { header('Location: index.php'); exit; }
    else { $error = 'Invalid credentials'; }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Login</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div class="login-container">
        <div class="card login-card">
            <h1>AirBoneRadio</h1>
            <h2>Login</h2>
            <?php if ($error): ?><div class="alert error"><?= htmlspecialchars($error) ?></div><?php endif; ?>
            <form method="POST" action="login.php">
                <div class="form-group">
                    <label for="username">Username</label>
                    <input type="text" id="username" name="username" required>
                </div>
                <div class="form-group">
                    <label for="password">Password</label>
                    <input type="password" id="password" name="password" required>
                </div>
                <button type="submit" class="btn btn-primary">Login</button>
            </form>
        </div>
    </div>
</body>
</html>
LOGINEOF

    cat > "$RADIO_DIR/app/logout.php" << 'LOGOUTEOF'
<?php require_once 'includes/auth.php'; logout(); header('Location: login.php'); exit;
LOGOUTEOF
    log "Login pages created"
}

create_dashboard() {
    log "Creating dashboard..."

    cat > "$RADIO_DIR/app/index.php" << 'INDEXEOF'
<?php require_once 'includes/config.php'; require_once 'includes/auth.php'; require_login(); generate_csrf();
$db = new PDO('sqlite:' . DB_PATH);
$settings = $db->query("SELECT * FROM settings")->fetchAll(PDO::FETCH_KEY_PAIR);
$songCount = $db->query("SELECT COUNT(*) FROM songs")->fetchColumn();
$streamFormat = strtoupper($settings['stream_format'] ?? 'MP3');
$streamBitrate = $settings['stream_bitrate'] ?? '128';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Dashboard</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo"><h2>AirBoneRadio</h2></div>
            <ul class="nav-menu">
                <li class="active"><a href="index.php">Dashboard</a></li>
                <li><a href="player.php">Web Player</a></li>
                <li><a href="library.php">Media Library</a></li>
                <li><a href="playlists.php">Playlists</a></li>
                <li><a href="settings.php">Settings</a></li>
                <li><a href="logout.php">Logout</a></li>
            </ul>
        </nav>
        <main class="content">
            <header><h1>Dashboard</h1></header>
            <div class="dashboard-grid">
                <div class="card status-card">
                    <h3>AutoDJ Status</h3>
                    <div class="status-indicator">
                        <span id="autodj-status" class="status-dot offline"></span>
                        <span id="autodj-text">Offline</span>
                    </div>
                    <div class="controls">
                        <button id="btn-start" class="btn btn-success">Start</button>
                        <button id="btn-stop" class="btn btn-danger">Stop</button>
                        <button id="btn-skip" class="btn btn-warning">Skip</button>
                    </div>
                </div>
                <div class="card now-playing-card">
                    <h3>Now Playing</h3>
                    <div id="now-playing">
                        <p class="track-title">No track playing</p>
                        <p class="track-artist">-</p>
                    </div>
                    <div style="margin-top: 15px;">
                        <a href="player.php" class="btn btn-primary" style="width:100%;text-align:center;">Open Web Player</a>
                    </div>
                </div>
                <div class="card stats-card">
                    <h3>Stream Info</h3>
                    <div class="stat"><span class="stat-value" id="listener-count">0</span><span class="stat-label">Listeners</span></div>
                    <div class="stat"><span class="stat-value" id="stream-bitrate"><?= $streamBitrate ?></span><span class="stat-label">kbps</span></div>
                    <div class="stat"><span class="stat-value" style="font-size:24px;"><?= $streamFormat ?></span><span class="stat-label">Format</span></div>
                    <div class="stat"><span class="stat-value" style="font-size:24px;"><?= $songCount ?></span><span class="stat-label">Songs</span></div>
                </div>
                <div class="card quick-actions-card">
                    <h3>Quick Actions</h3>
                    <div class="quick-actions">
                        <a href="library.php" class="btn btn-primary">Upload Music</a>
                        <a href="playlists.php" class="btn btn-primary">Manage Playlists</a>
                    </div>
                </div>
            </div>
        </main>
    </div>
    <script src="js/main.js"></script>
    <script>document.addEventListener('DOMContentLoaded', function() { updateStatus(); setInterval(updateStatus, 5000); });</script>
</body>
</html>
INDEXEOF
    log "Dashboard created"
}

create_library() {
    log "Creating library page..."

    cat > "$RADIO_DIR/app/library.php" << 'LIBEOF'
<?php require_once 'includes/config.php'; require_once 'includes/auth.php'; require_login(); generate_csrf();
$db = new PDO('sqlite:' . DB_PATH);
$songs = $db->query("SELECT * FROM songs ORDER BY uploaded_at DESC")->fetchAll(PDO::FETCH_ASSOC);
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Media Library</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo"><h2>AirBoneRadio</h2></div>
            <ul class="nav-menu">
                <li><a href="index.php">Dashboard</a></li>
                <li><a href="player.php">Web Player</a></li>
                <li class="active"><a href="library.php">Media Library</a></li>
                <li><a href="playlists.php">Playlists</a></li>
                <li><a href="settings.php">Settings</a></li>
                <li><a href="logout.php">Logout</a></li>
            </ul>
        </nav>
        <main class="content">
            <header>
                <h1>Media Library</h1>
                <button class="btn btn-primary" onclick="document.getElementById('upload-form').style.display='block'">Upload Music</button>
            </header>
            <div id="upload-form" class="card upload-form" style="display:none;">
                <h3>Upload Music (Max 20MB per file)</h3>
                <form id="uploadForm" enctype="multipart/form-data">
                    <input type="hidden" name="csrf_token" value="<?= htmlspecialchars($_SESSION['csrf_token']) ?>">
                    <div class="form-group">
                        <label for="audio_files">Select Audio Files (MP3, OGG, FLAC, WAV, M4A, AAC) - Multiple files allowed</label>
                        <input type="file" id="audio_files" name="files[]" accept=".mp3,.ogg,.flac,.wav,.m4a,.aac" multiple required>
                    </div>
                    <div class="form-group"><label for="title">Title (optional - applied to all)</label><input type="text" id="title" name="title"></div>
                    <div class="form-group"><label for="artist">Artist (optional - applied to all)</label><input type="text" id="artist" name="artist"></div>
                    <div id="uploadProgress" style="display:none; margin-bottom:15px;">
                        <p id="uploadStatus">Uploading...</p>
                    </div>
                    <div id="uploadMessages"></div>
                    <button type="submit" class="btn btn-primary" id="uploadBtn">Upload</button>
                    <button type="button" class="btn" onclick="document.getElementById('upload-form').style.display='none'">Cancel</button>
                </form>
            </div>
            <div class="card library-list">
                <table>
                    <thead><tr><th>Title</th><th>Artist</th><th>Duration</th><th>Uploaded</th><th>Actions</th></tr></thead>
                    <tbody id="songsTable">
                        <?php if (empty($songs)): ?>
                            <tr><td colspan="5" class="empty-state">No songs in library. Upload some music to get started!</td></tr>
                        <?php else: foreach ($songs as $song): ?>
                            <tr>
                                <td><?= htmlspecialchars($song['title'] ?: $song['original_name']) ?></td>
                                <td><?= htmlspecialchars($song['artist'] ?: '-') ?></td>
                                <td><?= isset($song['duration']) ? gmdate('i:s', $song['duration']) : '-' ?></td>
                                <td><?= date('Y-m-d', strtotime($song['uploaded_at'])) ?></td>
                                <td><button class="btn-icon" onclick="deleteSong(<?= $song['id'] ?>)" title="Delete">X</button></td>
                            </tr>
                        <?php endforeach; endif; ?>
                    </tbody>
                </table>
            </div>
        </main>
    </div>
    <script src="js/main.js"></script>
    <script>
        document.getElementById('uploadForm').addEventListener('submit', async function(e) {
            e.preventDefault();
            const form = e.target;
            const fileInput = document.getElementById('audio_files');
            const files = Array.from(fileInput.files || []);
            const btn = document.getElementById('uploadBtn');
            const progress = document.getElementById('uploadProgress');
            const status = document.getElementById('uploadStatus');
            const messages = document.getElementById('uploadMessages');

            if (files.length === 0) {
                messages.innerHTML = '<div class="alert error">Please select at least one file.</div>';
                return;
            }

            btn.disabled = true;
            btn.textContent = 'Uploading...';
            progress.style.display = 'block';
            messages.innerHTML = '';

            const csrfToken = form.querySelector('input[name="csrf_token"]').value;
            const title = document.getElementById('title').value;
            const artist = document.getElementById('artist').value;
            let totalUploaded = [];
            let totalErrors = [];
            let autodjStarted = false;
            let autodjFormat = '';
            let autodjBitrate = '';

            for (let i = 0; i < files.length; i++) {
                status.textContent = 'Uploading file ' + (i + 1) + ' of ' + files.length + '...';
                const formData = new FormData();
                formData.append('csrf_token', csrfToken);
                if (title) formData.append('title', title);
                if (artist) formData.append('artist', artist);
                formData.append('files[]', files[i]);

                try {
                    const response = await fetch('api/upload.php', { method: 'POST', body: formData });
                    const result = await response.json();
                    if (result.error) {
                        totalErrors.push('File ' + (i + 1) + ': ' + result.error);
                        continue;
                    }
                    if (result.uploaded) totalUploaded = totalUploaded.concat(result.uploaded);
                    if (result.errors) totalErrors = totalErrors.concat(result.errors);
                    if (result.autodj_started) {
                        autodjStarted = true;
                        autodjFormat = result.format;
                        autodjBitrate = result.bitrate;
                    }
                } catch (err) {
                    totalErrors.push('File ' + (i + 1) + ': ' + err.message);
                }
            }

            if (totalUploaded.length > 0) {
                let msg = 'Successfully uploaded ' + totalUploaded.length + ' file(s)!';
                if (autodjStarted) {
                    msg += '<br><strong>Stream started: ' + autodjFormat + ' @ ' + autodjBitrate + ' kbps</strong>';
                }
                messages.innerHTML = '<div class="alert success">' + msg + '</div>';
            }
            if (totalErrors.length > 0) {
                messages.innerHTML += '<div class="alert error">' + totalErrors.join('<br>') + '</div>';
            }
            if (totalUploaded.length === 0 && totalErrors.length === 0) {
                messages.innerHTML = '<div class="alert error">No files were uploaded. Please try again.</div>';
            }

            form.reset();
            btn.disabled = false;
            btn.textContent = 'Upload';
            progress.style.display = 'none';
            if (totalUploaded.length > 0) setTimeout(function() { location.reload(); }, 2000);
        });
    </script>
</body>
</html>
LIBEOF
    log "Library page created"
}

create_playlists() {
    log "Creating playlists page..."

    cat > "$RADIO_DIR/app/playlists.php" << 'PLAYEOF'
<?php require_once 'includes/config.php'; require_once 'includes/auth.php'; require_once 'includes/liquidsoap.php'; require_login(); generate_csrf();
$db = new PDO('sqlite:' . DB_PATH);
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    switch ($_POST['action']) {
        case 'create':
            $stmt = $db->prepare("INSERT INTO playlists (name, description, schedule_type, schedule_value, playback_order) VALUES (?, ?, ?, ?, ?)");
            $schedType = in_array($_POST['schedule_type'] ?? '', ['general','once_per_x_songs','once_per_x_minutes']) ? $_POST['schedule_type'] : 'general';
            $schedValue = max(1, (int)($_POST['schedule_value'] ?? 1));
            $playOrder = in_array($_POST['playback_order'] ?? '', ['shuffled','random','sequential']) ? $_POST['playback_order'] : 'shuffled';
            $stmt->execute([$_POST['name'], $_POST['description'] ?? '', $schedType, $schedValue, $playOrder]);
            break;
        case 'update':
            $schedType = in_array($_POST['schedule_type'] ?? '', ['general','once_per_x_songs','once_per_x_minutes']) ? $_POST['schedule_type'] : 'general';
            $schedValue = max(1, (int)($_POST['schedule_value'] ?? 1));
            $playOrder = in_array($_POST['playback_order'] ?? '', ['shuffled','random','sequential']) ? $_POST['playback_order'] : 'shuffled';
            $stmt = $db->prepare("UPDATE playlists SET name = ?, description = ?, schedule_type = ?, schedule_value = ?, playback_order = ? WHERE id = ?");
            $stmt->execute([$_POST['name'], $_POST['description'] ?? '', $schedType, $schedValue, $playOrder, (int)$_POST['id']]);
            exportPlaylistM3U((int)$_POST['id']);
            break;
        case 'delete':
            $id = (int)$_POST['id'];
            $db->prepare("DELETE FROM playlist_songs WHERE playlist_id = ?")->execute([$id]);
            $db->prepare("DELETE FROM playlists WHERE id = ?")->execute([$id]);
            @unlink(PLAYLISTS_DIR . '/' . $id . '.m3u');
            break;
        case 'add_songs':
            $playlistId = (int)$_POST['playlist_id'];
            $songIds = is_array($_POST['song_ids']) ? $_POST['song_ids'] : [$_POST['song_ids']];
            $maxPos = (int)$db->query("SELECT MAX(position) FROM playlist_songs WHERE playlist_id = $playlistId")->fetchColumn() ?: 0;
            $stmt = $db->prepare("INSERT INTO playlist_songs (playlist_id, song_id, position) VALUES (?, ?, ?)");
            foreach ($songIds as $songId) { if (!empty($songId)) { $maxPos++; $stmt->execute([$playlistId, (int)$songId, $maxPos]); } }
            exportPlaylistM3U($playlistId);
            break;
        case 'add_song':
            $playlistId = (int)$_POST['playlist_id'];
            $maxPos = $db->query("SELECT MAX(position) FROM playlist_songs WHERE playlist_id = " . $playlistId)->fetchColumn();
            $stmt = $db->prepare("INSERT INTO playlist_songs (playlist_id, song_id, position) VALUES (?, ?, ?)");
            $stmt->execute([$playlistId, $_POST['song_id'], ($maxPos ?: 0) + 1]);
            exportPlaylistM3U($playlistId);
            break;
        case 'remove_song':
            $playlistId = (int)($_POST['playlist_id'] ?? 0);
            $stmt = $db->prepare("DELETE FROM playlist_songs WHERE id = ?");
            $stmt->execute([$_POST['song_id']]);
            if ($playlistId > 0) exportPlaylistM3U($playlistId);
            break;
        case 'export':
            $playlistSongs = $db->query("SELECT s.filename FROM playlist_songs ps JOIN songs s ON ps.song_id = s.id WHERE ps.playlist_id = " . (int)$_POST['id'] . " ORDER BY ps.position")->fetchAll(PDO::FETCH_COLUMN);
            header('Content-Type: audio/x-mpegurl');
            header('Content-Disposition: attachment; filename="' . preg_replace('/[^a-zA-Z0-9_-]/', '_', $_POST['name'] ?? 'playlist') . '.m3u"');
            echo "#EXTM3U\n";
            foreach ($playlistSongs as $filename) { echo MUSIC_DIR . "/" . $filename . "\n"; }
            exit;
    }
    header('Location: playlists.php'); exit;
}
$playlists = $db->query("SELECT * FROM playlists ORDER BY created_at DESC")->fetchAll(PDO::FETCH_ASSOC);
$songs = $db->query("SELECT * FROM songs ORDER BY title")->fetchAll(PDO::FETCH_ASSOC);
function scheduleLabel($type, $value) { switch ($type) { case 'once_per_x_songs': return "Every {$value} songs"; case 'once_per_x_minutes': return "Every {$value} min"; default: return "General (weight: {$value})"; } }
function orderLabel($order) { switch ($order) { case 'random': return 'Random'; case 'sequential': return 'Sequential'; default: return 'Shuffled'; } }
function scheduleBadgeClass($type) { switch ($type) { case 'once_per_x_songs': return 'badge-songs'; case 'once_per_x_minutes': return 'badge-minutes'; default: return 'badge-general'; } }
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Playlists</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo"><h2>AirBoneRadio</h2></div>
            <ul class="nav-menu">
                <li><a href="index.php">Dashboard</a></li>
                <li><a href="player.php">Web Player</a></li>
                <li><a href="library.php">Media Library</a></li>
                <li class="active"><a href="playlists.php">Playlists</a></li>
                <li><a href="settings.php">Settings</a></li>
                <li><a href="logout.php">Logout</a></li>
            </ul>
        </nav>
        <main class="content">
            <header>
                <h1>Playlists</h1>
                <button class="btn btn-primary" onclick="document.getElementById('create-form').style.display='block'">Create Playlist</button>
            </header>
            <div id="create-form" class="card create-form" style="display:none;">
                <h3>Create Playlist</h3>
                <form method="POST"><input type="hidden" name="action" value="create">
                    <div class="form-group"><label for="name">Playlist Name</label><input type="text" id="name" name="name" required></div>
                    <div class="form-group"><label for="description">Description</label><textarea id="description" name="description"></textarea></div>
                    <div class="form-group"><label for="schedule_type">Playlist Type</label><select id="schedule_type" name="schedule_type" onchange="toggleScheduleFields(this, 'create')"><option value="general">General Rotation</option><option value="once_per_x_songs">Once per X Songs</option><option value="once_per_x_minutes">Once per X Minutes</option></select></div>
                    <div class="form-group schedule-field" id="create-value-group"><label id="create-value-label" for="schedule_value">Weight</label><input type="number" id="schedule_value" name="schedule_value" value="1" min="1" max="59"><small id="create-value-help" class="form-help">Higher weight = more songs from this playlist in rotation</small></div>
                    <div class="form-group"><label for="playback_order">Playback Order</label><select id="playback_order" name="playback_order"><option value="shuffled">Shuffled</option><option value="random">Random</option><option value="sequential">Sequential</option></select><small class="form-help">Shuffled: shuffle then play through. Random: random pick each time. Sequential: play in order.</small></div>
                    <button type="submit" class="btn btn-primary">Create</button>
                    <button type="button" class="btn" onclick="document.getElementById('create-form').style.display='none'">Cancel</button>
                </form>
            </div>
            <div class="playlists-grid">
                <?php foreach ($playlists as $playlist):
                    $playlistSongs = $db->query("SELECT ps.id as ps_id, s.* FROM playlist_songs ps JOIN songs s ON ps.song_id = s.id WHERE ps.playlist_id = {$playlist['id']} ORDER BY ps.position")->fetchAll(PDO::FETCH_ASSOC);
                    $schedType = $playlist['schedule_type'] ?? 'general'; $schedValue = (int)($playlist['schedule_value'] ?? 1); $playOrder = $playlist['playback_order'] ?? 'shuffled';
                ?>
                    <div class="card playlist-card">
                        <div class="playlist-header"><h3><?= htmlspecialchars($playlist['name']) ?></h3><span class="song-count"><?= count($playlistSongs) ?> songs</span></div>
                        <div class="playlist-badges"><span class="badge <?= scheduleBadgeClass($schedType) ?>"><?= scheduleLabel($schedType, $schedValue) ?></span><span class="badge badge-order"><?= orderLabel($playOrder) ?></span></div>
                        <p class="playlist-desc"><?= htmlspecialchars($playlist['description'] ?? 'No description') ?></p>
                        <div class="playlist-actions">
                            <button type="button" class="btn btn-small" onclick="toggleEditForm(<?= $playlist['id'] ?>)">Edit</button>
                            <form method="POST" style="display:inline;"><input type="hidden" name="action" value="export"><input type="hidden" name="id" value="<?= $playlist['id'] ?>"><input type="hidden" name="name" value="<?= htmlspecialchars($playlist['name']) ?>"><button type="submit" class="btn btn-small">Export .m3u</button></form>
                            <form method="POST" style="display:inline;" onsubmit="return confirm('Delete playlist?');"><input type="hidden" name="action" value="delete"><input type="hidden" name="id" value="<?= $playlist['id'] ?>"><button type="submit" class="btn btn-small btn-danger">Delete</button></form>
                        </div>
                        <div id="edit-form-<?= $playlist['id'] ?>" class="edit-form" style="display:none;">
                            <form method="POST"><input type="hidden" name="action" value="update"><input type="hidden" name="id" value="<?= $playlist['id'] ?>">
                                <div class="form-group"><label>Playlist Name</label><input type="text" name="name" value="<?= htmlspecialchars($playlist['name']) ?>" required></div>
                                <div class="form-group"><label>Description</label><textarea name="description"><?= htmlspecialchars($playlist['description'] ?? '') ?></textarea></div>
                                <div class="form-group"><label>Playlist Type</label><select name="schedule_type" onchange="toggleScheduleFields(this, '<?= $playlist['id'] ?>')"><option value="general"<?= $schedType === 'general' ? ' selected' : '' ?>>General Rotation</option><option value="once_per_x_songs"<?= $schedType === 'once_per_x_songs' ? ' selected' : '' ?>>Once per X Songs</option><option value="once_per_x_minutes"<?= $schedType === 'once_per_x_minutes' ? ' selected' : '' ?>>Once per X Minutes</option></select></div>
                                <div class="form-group schedule-field" id="edit-value-group-<?= $playlist['id'] ?>"><label id="edit-value-label-<?= $playlist['id'] ?>"><?php if ($schedType === 'once_per_x_songs') echo 'Every X Songs'; elseif ($schedType === 'once_per_x_minutes') echo 'Every X Minutes'; else echo 'Weight'; ?></label><input type="number" name="schedule_value" value="<?= $schedValue ?>" min="1" max="59"></div>
                                <div class="form-group"><label>Playback Order</label><select name="playback_order"><option value="shuffled"<?= $playOrder === 'shuffled' ? ' selected' : '' ?>>Shuffled</option><option value="random"<?= $playOrder === 'random' ? ' selected' : '' ?>>Random</option><option value="sequential"<?= $playOrder === 'sequential' ? ' selected' : '' ?>>Sequential</option></select></div>
                                <button type="submit" class="btn btn-small btn-primary">Save</button>
                                <button type="button" class="btn btn-small" onclick="toggleEditForm(<?= $playlist['id'] ?>)">Cancel</button>
                            </form>
                        </div>
                        <div class="playlist-songs">
                            <h4>Songs</h4>
                            <?php if (empty($playlistSongs)): ?><p class="empty-state">No songs in playlist</p>
                            <?php else: ?><ul><?php foreach ($playlistSongs as $song): ?><li><?= htmlspecialchars($song['title'] ?: $song['original_name']) ?><form method="POST" style="display:inline;"><input type="hidden" name="action" value="remove_song"><input type="hidden" name="song_id" value="<?= $song['ps_id'] ?>"><input type="hidden" name="playlist_id" value="<?= $playlist['id'] ?>"><button type="submit" class="btn-icon small">X</button></form></li><?php endforeach; ?></ul><?php endif; ?>
                            <form method="POST" class="add-song-form"><input type="hidden" name="action" value="add_songs"><input type="hidden" name="playlist_id" value="<?= $playlist['id'] ?>"><select name="song_ids[]" multiple size="5" class="multi-select" required><?php foreach ($songs as $song): ?><option value="<?= $song['id'] ?>"><?= htmlspecialchars($song['title'] ?: $song['original_name']) ?></option><?php endforeach; ?></select><div style="display:flex;gap:8px;margin-top:8px;"><button type="submit" class="btn btn-small btn-primary">Add Selected</button><button type="button" class="btn btn-small" onclick="selectAllSongs(this)">Select All</button></div></form>
                        </div>
                    </div>
                <?php endforeach; ?>
                <?php if (empty($playlists)): ?><div class="card empty-state">No playlists yet. Create one to get started!</div><?php endif; ?>
            </div>
        </main>
    </div>
    <script src="js/main.js"></script>
    <script>
    function selectAllSongs(btn){var sel=btn.closest('form').querySelector('.multi-select');var opts=sel.options;for(var i=0;i<opts.length;i++)opts[i].selected=true;}
    function toggleEditForm(id){var el=document.getElementById('edit-form-'+id);el.style.display=(el.style.display==='none')?'block':'none';}
    function toggleScheduleFields(sel, ctx){
        var type=sel.value;var labelEl,groupEl,helpEl,inputEl;
        if(ctx==='create'){labelEl=document.getElementById('create-value-label');groupEl=document.getElementById('create-value-group');helpEl=document.getElementById('create-value-help');inputEl=groupEl.querySelector('input[name="schedule_value"]');}
        else{labelEl=document.getElementById('edit-value-label-'+ctx);groupEl=document.getElementById('edit-value-group-'+ctx);helpEl=null;inputEl=groupEl.querySelector('input[name="schedule_value"]');}
        switch(type){
            case 'general':labelEl.textContent='Weight';if(helpEl)helpEl.textContent='Higher weight = more songs from this playlist in rotation';inputEl.min='1';inputEl.max='100';inputEl.value='1';break;
            case 'once_per_x_songs':labelEl.textContent='Every X Songs';if(helpEl)helpEl.textContent='Play one song from this playlist every X songs';inputEl.min='1';inputEl.max='100';inputEl.value='5';break;
            case 'once_per_x_minutes':labelEl.textContent='Every X Minutes';if(helpEl)helpEl.textContent='Play one song from this playlist every X minutes';inputEl.min='1';inputEl.max='360';inputEl.value='30';break;
        }
    }
    </script>
</body>
</html>
PLAYEOF
    log "Playlists page created"
}

create_settings() {
    log "Creating settings page..."

    cat > "$RADIO_DIR/app/settings.php" << 'SETEOF'
<?php require_once 'includes/config.php'; require_once 'includes/auth.php'; require_login(); generate_csrf();
$db = new PDO('sqlite:' . DB_PATH);
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    switch ($_POST['action']) {
        case 'change_password':
            $stmt = $db->prepare("SELECT password FROM users WHERE id = ?"); $stmt->execute([$_SESSION['user_id']]); $user = $stmt->fetch();
            if (!password_verify($_POST['current_password'], $user['password'])) { $error = 'Current password is incorrect'; break; }
            if ($_POST['new_password'] !== $_POST['confirm_password']) { $error = 'New passwords do not match'; break; }
            $stmt = $db->prepare("UPDATE users SET password = ? WHERE id = ?"); $stmt->execute([password_hash($_POST['new_password'], PASSWORD_DEFAULT), $_SESSION['user_id']]); $success = 'Password changed successfully'; break;
        case 'update_settings':
            $crossfadeSeconds = isset($_POST['crossfade_seconds']) ? (float)$_POST['crossfade_seconds'] : 0.0;
            if ($crossfadeSeconds < 0) $crossfadeSeconds = 0.0;
            if ($crossfadeSeconds > 12.9) $crossfadeSeconds = 12.9;
            $crossfadeSeconds = number_format($crossfadeSeconds, 1, '.', '');
            $stmt = $db->prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)");
            $stmt->execute(['station_name', $_POST['station_name'] ?? 'AirBoneRadio']);
            $stmt->execute(['station_description', $_POST['station_description'] ?? '']);
            $stmt->execute(['stream_format', $_POST['stream_format'] ?? 'mp3']);
            $stmt->execute(['stream_bitrate', $_POST['stream_bitrate'] ?? '128']);
            $stmt->execute(['crossfade_seconds', $crossfadeSeconds]);
            $stmt->execute(['crossfade_enabled', ((float)$crossfadeSeconds > 0 ? '1' : '0')]);
            $success = 'Settings updated. Restart AutoDJ to apply changes.';
            break;
    }
}
$settings = $db->query("SELECT * FROM settings")->fetchAll(PDO::FETCH_KEY_PAIR);
$stationName = $settings['station_name'] ?? 'AirBoneRadio';
$stationDesc = $settings['station_description'] ?? '';
$streamFormat = $settings['stream_format'] ?? 'mp3';
$streamBitrate = $settings['stream_bitrate'] ?? '128';
$crossfadeSeconds = $settings['crossfade_seconds'] ?? (($settings['crossfade_enabled'] ?? '0') === '1' ? '3.0' : '0.0');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Settings</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo"><h2>AirBoneRadio</h2></div>
            <ul class="nav-menu">
                <li><a href="index.php">Dashboard</a></li>
                <li><a href="player.php">Web Player</a></li>
                <li><a href="library.php">Media Library</a></li>
                <li><a href="playlists.php">Playlists</a></li>
                <li class="active"><a href="settings.php">Settings</a></li>
                <li><a href="logout.php">Logout</a></li>
            </ul>
        </nav>
        <main class="content">
            <header><h1>Settings</h1></header>
            <?php if (isset($error)): ?><div class="alert error"><?= htmlspecialchars($error) ?></div><?php endif; ?>
            <?php if (isset($success)): ?><div class="alert success"><?= htmlspecialchars($success) ?></div><?php endif; ?>
            <div class="settings-grid">
                <div class="card"><h3>Station Settings</h3>
                    <form method="POST"><input type="hidden" name="action" value="update_settings">
                        <div class="form-group"><label for="station_name">Station Name</label><input type="text" id="station_name" name="station_name" value="<?= htmlspecialchars($stationName) ?>"></div>
                        <div class="form-group"><label for="station_description">Description</label><textarea id="station_description" name="station_description"><?= htmlspecialchars($stationDesc) ?></textarea></div>
                        <div class="form-group"><label for="stream_format">Broadcast Format</label>
                            <select id="stream_format" name="stream_format">
                                <option value="mp3" <?= $streamFormat=='mp3'?'selected':'' ?>>MP3 (Most Compatible)</option>
                                <option value="aac" <?= $streamFormat=='aac'?'selected':'' ?>>AAC (High Efficiency)</option>
                                <option value="ogg" <?= $streamFormat=='ogg'?'selected':'' ?>>OGG Vorbis (Open Source)</option>
                            </select>
                        </div>
                        <div class="form-group"><label for="stream_bitrate">Bitrate (kbps)</label>
                            <select id="stream_bitrate" name="stream_bitrate">
                                <option value="64" <?= $streamBitrate=='64'?'selected':'' ?>>64 (Low Bandwidth)</option>
                                <option value="96" <?= $streamBitrate=='96'?'selected':'' ?>>96 (Standard)</option>
                                <option value="112" <?= $streamBitrate=='112'?'selected':'' ?>>112 (Balanced)</option>
                                <option value="128" <?= $streamBitrate=='128'?'selected':'' ?>>128 (Recommended)</option>
                                <option value="192" <?= $streamBitrate=='192'?'selected':'' ?>>192 (High Quality)</option>
                                <option value="256" <?= $streamBitrate=='256'?'selected':'' ?>>256 (Very High)</option>
                                <option value="320" <?= $streamBitrate=='320'?'selected':'' ?>>320 (Maximum)</option>
                            </select>
                        </div>
                        <div class="form-group"><label for="crossfade_seconds">Crossfade Duration (seconds)</label><input type="number" id="crossfade_seconds" name="crossfade_seconds" min="0" max="12.9" step="0.1" value="<?= htmlspecialchars($crossfadeSeconds) ?>"><small class="form-help">Range: 0.0 to 12.9 seconds. Use 0 to disable crossfade.</small></div>
                        <button type="submit" class="btn btn-primary">Save Settings</button>
                    </form>
                </div>
                <div class="card"><h3>Change Password</h3>
                    <form method="POST"><input type="hidden" name="action" value="change_password">
                        <div class="form-group"><label for="current_password">Current Password</label><input type="password" id="current_password" name="current_password" required></div>
                        <div class="form-group"><label for="new_password">New Password</label><input type="password" id="new_password" name="new_password" required></div>
                        <div class="form-group"><label for="confirm_password">Confirm New Password</label><input type="password" id="confirm_password" name="confirm_password" required></div>
                        <button type="submit" class="btn btn-primary">Change Password</button>
                    </form>
                </div>
                <div class="card"><h3>Stream Information</h3>
                    <div class="info-row"><span class="info-label">Stream URL:</span><span class="info-value">http://<?= $_SERVER['SERVER_NAME'] ?? 'localhost' ?>:8000/stream</span></div>
                    <div class="info-row"><span class="info-label">Format:</span><span class="info-value"><?= strtoupper($streamFormat) ?></span></div>
                    <div class="info-row"><span class="info-label">Bitrate:</span><span class="info-value"><?= $streamBitrate ?> kbps</span></div>
                    <div class="info-row"><span class="info-label">Crossfade:</span><span class="info-value"><?= (float)$crossfadeSeconds > 0 ? htmlspecialchars($crossfadeSeconds) . 's' : 'Disabled (0.0s)' ?></span></div>
                    <div class="info-row"><span class="info-label">Icecast Port:</span><span class="info-value">8000</span></div>
                </div>
            </div>
        </main>
    </div>
    <script src="js/main.js"></script>
</body>
</html>
SETEOF
    log "Settings page created"
}

create_player() {
    log "Creating player page..."

    cat > "$RADIO_DIR/app/player.php" << 'PLAYEREOF'
<?php require_once 'includes/config.php'; require_once 'includes/auth.php'; require_login(); generate_csrf();
$db = new PDO('sqlite:' . DB_PATH);
$settings = $db->query("SELECT * FROM settings")->fetchAll(PDO::FETCH_KEY_PAIR);
$stationName = $settings['station_name'] ?? 'AirBoneRadio';
$streamFormat = strtoupper($settings['stream_format'] ?? 'mp3');
$streamBitrate = $settings['stream_bitrate'] ?? '128';
$streamUrl = 'http://' . ($_SERVER['SERVER_NAME'] ?? 'localhost') . ':8000/stream';
$audioMime = ($streamFormat === 'OGG') ? 'audio/ogg' : (($streamFormat === 'AAC') ? 'audio/aac' : 'audio/mpeg');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirBoneRadio - Web Player</title>
    <link rel="stylesheet" href="css/style.css">
    <style>
        .player-container { max-width: 600px; margin: 0 auto; }
        .now-playing-display { text-align: center; padding: 30px; }
        .station-logo { width: 120px; height: 120px; border-radius: 50%; background: linear-gradient(135deg, var(--neon-orange), var(--lime-green)); display: flex; align-items: center; justify-content: center; margin: 0 auto 20px; animation: rotate 20s linear infinite; animation-play-state: paused; }
        .station-logo.playing { animation-play-state: running; }
        @keyframes rotate { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        .vinyl-center { width: 40px; height: 40px; background: var(--bg-primary); border-radius: 50%; border: 3px solid var(--neon-orange); }
        .track-info { margin: 20px 0; }
        .waveform { display: flex; justify-content: center; align-items: center; gap: 4px; height: 60px; margin: 20px 0; }
        .waveform-bar { width: 6px; background: var(--neon-orange); border-radius: 3px; transition: height 0.1s ease; }
        .waveform.playing .waveform-bar { animation: wave 0.5s ease-in-out infinite; }
        @keyframes wave { 0%, 100% { height: 20px; } 50% { height: 50px; } }
        .waveform .waveform-bar:nth-child(1) { animation-delay: 0s; }
        .waveform .waveform-bar:nth-child(2) { animation-delay: 0.1s; }
        .waveform .waveform-bar:nth-child(3) { animation-delay: 0.2s; }
        .waveform .waveform-bar:nth-child(4) { animation-delay: 0.3s; }
        .waveform .waveform-bar:nth-child(5) { animation-delay: 0.4s; }
        .waveform .waveform-bar:nth-child(6) { animation-delay: 0.5s; }
        .waveform .waveform-bar:nth-child(7) { animation-delay: 0.6s; }
        .waveform .waveform-bar:nth-child(8) { animation-delay: 0.7s; }
        .waveform .waveform-bar:nth-child(9) { animation-delay: 0.8s; }
        .waveform .waveform-bar:nth-child(10) { animation-delay: 0.9s; }
        .waveform .waveform-bar:nth-child(11) { animation-delay: 1.0s; }
        .waveform .waveform-bar:nth-child(12) { animation-delay: 1.1s; }
        .play-button { width: 80px; height: 80px; border-radius: 50%; background: var(--neon-orange); border: none; cursor: pointer; display: flex; align-items: center; justify-content: center; margin: 0 auto; transition: all 0.3s ease; box-shadow: 0 0 30px rgba(255, 102, 0, 0.5); }
        .play-button:hover { transform: scale(1.1); box-shadow: 0 0 50px rgba(255, 102, 0, 0.8); }
        .play-button svg { width: 30px; height: 30px; fill: var(--bg-primary); }
        .volume-control { display: flex; align-items: center; gap: 15px; justify-content: center; margin-top: 20px; }
        .volume-icon { color: var(--lime-green); cursor: pointer; }
        .volume-slider { width: 150px; height: 8px; -webkit-appearance: none; background: var(--bg-secondary); border-radius: 4px; outline: none; }
        .volume-slider::-webkit-slider-thumb { -webkit-appearance: none; width: 20px; height: 20px; background: var(--neon-orange); border-radius: 50%; cursor: pointer; box-shadow: 0 0 10px var(--neon-orange); }
        .volume-slider::-moz-range-thumb { width: 20px; height: 20px; background: var(--neon-orange); border-radius: 50%; cursor: pointer; border: none; box-shadow: 0 0 10px var(--neon-orange); }
        .status-badge { display: inline-flex; align-items: center; gap: 8px; padding: 8px 16px; background: var(--bg-secondary); border-radius: 20px; font-size: 14px; color: var(--text-secondary); margin-top: 15px; }
        .status-badge .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--danger); }
        .status-badge.live .dot { background: var(--lime-green); animation: pulse 1s infinite; }
        .listener-count { font-size: 24px; color: var(--lime-green); margin-top: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo"><h2>AirBoneRadio</h2></div>
            <ul class="nav-menu">
                <li><a href="index.php">Dashboard</a></li>
                <li class="active"><a href="player.php">Web Player</a></li>
                <li><a href="library.php">Media Library</a></li>
                <li><a href="playlists.php">Playlists</a></li>
                <li><a href="settings.php">Settings</a></li>
                <li><a href="logout.php">Logout</a></li>
            </ul>
        </nav>
        <main class="content">
            <header><h1>Web Player</h1></header>
            <div class="player-container">
                <div class="card">
                    <div class="now-playing-display">
                        <div class="station-logo" id="stationLogo"><div class="vinyl-center"></div></div>
                        <div class="track-info">
                            <p class="track-title" id="playerTitle">Stream Offline</p>
                            <p class="track-artist" id="playerArtist"><?= htmlspecialchars($stationName) ?></p>
                        </div>
                        <div class="waveform" id="waveform">
                            <?php for ($i = 1; $i <= 12; $i++): ?>
                                <div class="waveform-bar" style="height: <?= rand(15, 40) ?>px;"></div>
                            <?php endfor; ?>
                        </div>
                        <button class="play-button" id="playButton" onclick="togglePlay()">
                            <svg id="playIcon" viewBox="0 0 24 24"><polygon points="5,3 19,12 5,21"/></svg>
                        </button>
                        <div class="volume-control">
                            <span class="volume-icon" onclick="toggleMute()">
                                <svg id="volumeIcon" width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                                    <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/>
                                </svg>
                            </span>
                            <input type="range" class="volume-slider" id="volumeSlider" min="0" max="100" value="80" oninput="setVolume(this.value)">
                        </div>
                        <div style="text-align: center;">
                            <div class="status-badge" id="statusBadge">
                                <span class="dot"></span>
                                <span id="statusText">Click Play to Start</span>
                            </div>
                            <p class="listener-count"><span id="listenerCount">0</span> Listeners</p>
                        </div>
                    </div>
                </div>
                <div class="card">
                    <h3>Stream Info</h3>
                    <div class="info-row"><span class="info-label">Station:</span><span class="info-value"><?= htmlspecialchars($stationName) ?></span></div>
                    <div class="info-row"><span class="info-label">Stream URL:</span><span class="info-value"><?= $streamUrl ?></span></div>
                    <div class="info-row"><span class="info-label">Format:</span><span class="info-value"><?= $streamFormat ?> <?= $streamBitrate ?>kbps</span></div>
                    <div class="info-row"><span class="info-label">Status:</span><span class="info-value" id="serverStatus">Checking...</span></div>
                </div>
            </div>
        </main>
    </div>
    <audio id="audioPlayer" preload="none"><source src="<?= $streamUrl ?>" type="<?= $audioMime ?>"></audio>
    <script src="js/main.js"></script>
    <script>
        var audio = document.getElementById('audioPlayer');
        var playButton = document.getElementById('playButton');
        var playIcon = document.getElementById('playIcon');
        var stationLogo = document.getElementById('stationLogo');
        var waveform = document.getElementById('waveform');
        var statusBadge = document.getElementById('statusBadge');
        var statusText = document.getElementById('statusText');
        var serverStatus = document.getElementById('serverStatus');
        var volumeSlider = document.getElementById('volumeSlider');
        var volumeIcon = document.getElementById('volumeIcon');
        var isPlaying = false;
        var previousVolume = 80;
        var isMuted = false;

        function applyOutputVolume() {
            var base = (isMuted ? 0 : (parseFloat(volumeSlider.value) / 100));
            audio.volume = base;
        }

        function togglePlay() {
            if (isPlaying) {
                audio.pause(); isPlaying = false;
                playIcon.innerHTML = '<polygon points="5,3 19,12 5,21"/>';
                stationLogo.classList.remove('playing'); waveform.classList.remove('playing');
                statusBadge.classList.remove('live'); statusText.textContent = 'Paused';
            } else {
                audio.play().then(function() {
                    isPlaying = true;
                    playIcon.innerHTML = '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>';
                    stationLogo.classList.add('playing'); waveform.classList.add('playing');
                    statusBadge.classList.add('live'); statusText.textContent = 'LIVE';
                    updatePlayerInfo();
                }).catch(function() { alert('Unable to play stream. Make sure AutoDJ is running.'); });
            }
        }
        function setVolume(val) {
            previousVolume = val;
            if (parseFloat(val) > 0) isMuted = false;
            applyOutputVolume();
            if (val == 0) { volumeIcon.innerHTML = '<path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/>'; }
            else { volumeIcon.innerHTML = '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/>'; }
        }
        function toggleMute() {
            if (!isMuted) {
                previousVolume = volumeSlider.value;
                isMuted = true;
                volumeSlider.value = 0;
            } else {
                isMuted = false;
                volumeSlider.value = previousVolume;
            }
            setVolume(volumeSlider.value);
        }

        function updatePlayerInfo() {
            fetch('api/nowplaying.php').then(function(r) { return r.json(); }).then(function(data) {
                if (data.autodj_status === 'running') { serverStatus.textContent = 'Online'; serverStatus.style.color = 'var(--lime-green)'; }
                else { serverStatus.textContent = 'Offline'; serverStatus.style.color = 'var(--danger)'; }
            });
        }
        function updateListeners() {
            fetch('api/listeners.php').then(function(r) { return r.json(); }).then(function(data) {
                document.getElementById('listenerCount').textContent = data.listeners || 0;
            });
        }
        audio.addEventListener('error', function() {
            if (isPlaying) { isPlaying = false; playIcon.innerHTML = '<polygon points="5,3 19,12 5,21"/>'; stationLogo.classList.remove('playing'); waveform.classList.remove('playing'); statusBadge.classList.remove('live'); statusText.textContent = 'Stream Error'; }
        });
        audio.addEventListener('waiting', function() { statusText.textContent = 'Buffering...'; });
        audio.addEventListener('playing', function() { statusBadge.classList.add('live'); statusText.textContent = 'LIVE'; });
        setVolume(volumeSlider.value);
        updatePlayerInfo(); updateListeners();
        setInterval(updatePlayerInfo, 10000); setInterval(updateListeners, 5000);
    </script>
</body>
</html>
PLAYEREOF
    log "Player page created"
}

create_api() {
    log "Creating API endpoints..."

    cat > "$RADIO_DIR/app/api/nowplaying.php" << 'NPEOF'
<?php header('Content-Type: application/json');
$response = ['title' => 'Offline', 'artist' => '', 'listeners' => 0, 'autodj_status' => 'offline'];
$pidFile = '/var/run/airbone/autodj.pid';
if (file_exists($pidFile)) {
    $pid = trim(file_get_contents($pidFile));
    if ($pid && (function_exists('posix_getpgid') ? @posix_getpgid((int)$pid) : file_exists("/proc/$pid"))) {
        $response['autodj_status'] = 'running';
        $response['title'] = 'Live Stream';
        // Try to get track info from Icecast admin stats
        $ctx = stream_context_create(['http' => [
            'header' => 'Authorization: Basic ' . base64_encode('admin:airbone_admin_pass'),
            'timeout' => 3
        ]]);
        $data = @file_get_contents('http://127.0.0.1:8000/admin/stats', false, $ctx);
        if ($data) {
            $xml = @simplexml_load_string($data);
            if ($xml && isset($xml->source)) {
                $src = null;
                foreach ($xml->source as $candidate) {
                    $mountAttr = (string)($candidate['mount'] ?? '');
                    if ($mountAttr === '/stream') { $src = $candidate; break; }
                }
                if ($src === null) { $src = $xml->source[0]; }
                if (isset($src->title) && (string)$src->title !== '') {
                    $response['title'] = (string)$src->title;
                } elseif (isset($src->server_name) && (string)$src->server_name !== '') {
                    $response['title'] = (string)$src->server_name;
                }
                if (isset($src->artist)) {
                    $response['artist'] = (string)$src->artist;
                }
                $response['listeners'] = (int)($src->listeners ?? 0);
            }
        }
    }
}
echo json_encode($response);
NPEOF

    cat > "$RADIO_DIR/app/api/listeners.php" << 'LISTEOF'
<?php header('Content-Type: application/json');
$response = ['listeners' => 0, 'peak' => 0, 'max' => 100];
$ctx = stream_context_create(['http' => [
    'header' => 'Authorization: Basic ' . base64_encode('admin:airbone_admin_pass'),
    'timeout' => 3
]]);
$data = @file_get_contents('http://127.0.0.1:8000/admin/stats', false, $ctx);
if ($data) {
    $xml = @simplexml_load_string($data);
    if ($xml) {
        if (isset($xml->source)) {
            $src = null;
            foreach ($xml->source as $candidate) {
                $mountAttr = (string)($candidate['mount'] ?? '');
                if ($mountAttr === '/stream') { $src = $candidate; break; }
            }
            if ($src === null) { $src = $xml->source[0]; }
            $response['listeners'] = (int)($src->listeners ?? 0);
        } else {
            $response['listeners'] = (int)($xml->listeners ?? 0);
        }
    }
}
echo json_encode($response);
LISTEOF

    cat > "$RADIO_DIR/app/api/start.php" << 'STARTEOF'
<?php
header('Content-Type: application/json');
error_reporting(0);
@ini_set('display_errors', 0);

require_once __DIR__ . '/../includes/config.php';
require_once __DIR__ . '/../includes/liquidsoap.php';

$liqBin = escapeshellarg(getLiquidsoapBinary());

$pidDir = '/var/run/airbone';
@mkdir($pidDir, 0755, true);
@chown($pidDir, 'www-data');
$pidFile = "$pidDir/autodj.pid";

if (file_exists($pidFile)) {
    $pid = trim(file_get_contents($pidFile));
    if ($pid && (function_exists('posix_getpgid') ? @posix_getpgid((int)$pid) : file_exists("/proc/$pid"))) {
        echo json_encode(['status' => 'already_running', 'pid' => $pid]);
        exit;
    }
}

try {
    $db = new PDO('sqlite:' . DB_PATH);
} catch (Exception $e) {
    echo json_encode(['status' => 'error', 'message' => 'Database connection failed']);
    exit;
}

$songCount = $db->query("SELECT COUNT(*) FROM songs")->fetchColumn();
if ($songCount == 0) {
    echo json_encode(['status' => 'error', 'message' => 'No songs in library. Upload music first.']);
    exit;
}

// Verify Icecast is running before starting Liquidsoap
$icecastUp = @fsockopen('127.0.0.1', 8000, $errno, $errstr, 2);
if (!$icecastUp) {
    @exec("service icecast2 start 2>/dev/null");
    sleep(2);
    $icecastUp = @fsockopen('127.0.0.1', 8000, $errno, $errstr, 2);
    if (!$icecastUp) {
        echo json_encode(['status' => 'error', 'message' => 'Icecast is not running on port 8000. Start Icecast first.']);
        exit;
    }
}
fclose($icecastUp);

// Generate Liquidsoap script using shared helper
$result = generateLiquidsoapScript();
$format = $result['format'];
$bitrate = $result['bitrate'];

@file_put_contents('/var/www/airbone/autodj.liq', $result['script']);
@chmod('/var/www/airbone/autodj.liq', 0644);
@mkdir('/var/log/airbone', 0755, true);

$checkOut = [];
$checkCode = 0;
@exec("cd /var/www/airbone && {$liqBin} --check autodj.liq 2>&1", $checkOut, $checkCode);
if ($checkCode !== 0) {
    $err = trim(implode("\n", array_slice($checkOut, -8)));
    echo json_encode(['status' => 'failed', 'message' => 'Liquidsoap script validation failed: ' . ($err !== '' ? $err : 'unknown parse error')]);
    exit;
}

@shell_exec("pkill -f 'liquidsoap' 2>/dev/null");
@usleep(500000);

$cmd = "cd /var/www/airbone && nohup {$liqBin} autodj.liq > /var/log/airbone/autodj.log 2>&1 & echo \$!";
@shell_exec($cmd);
sleep(3);

$pid = trim(@shell_exec("pgrep -f 'liquidsoap' | head -1"));
if ($pid) {
    @file_put_contents($pidFile, $pid);
    @chmod($pidFile, 0644);
    echo json_encode(['status' => 'started', 'pid' => $pid, 'format' => $format, 'bitrate' => $bitrate, 'songs' => $songCount]);
} else {
    echo json_encode(['status' => 'failed', 'message' => 'Check /var/log/airbone/autodj.log']);
}
STARTEOF

    cat > "$RADIO_DIR/app/api/stop.php" << 'STOPEOF'
<?php header('Content-Type: application/json');
$pidFile = '/var/run/airbone/autodj.pid';
if (file_exists($pidFile)) {
    $pid = trim(file_get_contents($pidFile));
    if ($pid) { @exec("kill $pid 2>/dev/null"); @exec("pkill -f 'liquidsoap' 2>/dev/null"); }
    @unlink($pidFile);
}
echo json_encode(['status' => 'stopped']);
STOPEOF

    cat > "$RADIO_DIR/app/api/skip.php" << 'SKIPEOF'
<?php header('Content-Type: application/json'); require_once __DIR__ . '/../includes/liquidsoap.php';
$pidFile = '/var/run/airbone/autodj.pid';
if (file_exists($pidFile)) {
    $pid = trim(file_get_contents($pidFile));
    if ($pid && (function_exists('posix_getpgid') ? @posix_getpgid((int)$pid) : file_exists("/proc/$pid"))) {
        // Liquidsoap 1.1.4: restart to skip to next track
        @exec("kill $pid 2>/dev/null");
        @exec("pkill -f 'liquidsoap' 2>/dev/null");
        @unlink($pidFile);
        usleep(500000);
        $liqBin = escapeshellarg(getLiquidsoapBinary());
        $cmd = "cd /var/www/airbone && nohup {$liqBin} autodj.liq > /var/log/airbone/autodj.log 2>&1 & echo \$!";
        @shell_exec($cmd);
        sleep(2);
        $newPid = trim(@shell_exec("pgrep -f 'liquidsoap' | head -1"));
        if ($newPid) {
            @file_put_contents($pidFile, $newPid);
            echo json_encode(['status' => 'skipped']);
        } else {
            echo json_encode(['status' => 'error', 'message' => 'Failed to restart after skip']);
        }
        exit;
    }
}
echo json_encode(['status' => 'error', 'message' => 'AutoDJ not running']);
SKIPEOF

    cat > "$RADIO_DIR/app/api/upload.php" << 'UPLOADEOF'
<?php
require_once __DIR__ . '/../includes/config.php';
require_once __DIR__ . '/../includes/liquidsoap.php';
header('Content-Type: application/json');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); echo json_encode(['error' => 'Method not allowed']); exit; }
session_start();
if (!isset($_SESSION['user_id'])) { http_response_code(401); echo json_encode(['error' => 'Unauthorized']); exit; }

// Detect if request exceeded post_max_size and PHP dropped payload
if (empty($_POST) && empty($_FILES) && isset($_SERVER['CONTENT_LENGTH']) && (int)$_SERVER['CONTENT_LENGTH'] > 0) {
    $maxPost = ini_get('post_max_size');
    echo json_encode(['error' => "Upload too large. The server limit is {$maxPost}. Try uploading fewer files at a time."]);
    exit;
}

// Handle delete action
if (isset($_POST['action']) && $_POST['action'] === 'delete' && isset($_POST['id'])) {
    $db = new PDO('sqlite:' . DB_PATH);
    $stmt = $db->prepare("SELECT filename FROM songs WHERE id = ?"); $stmt->execute([(int)$_POST['id']]); $song = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($song) {
        $filepath = MUSIC_DIR . '/' . $song['filename'];
        if (file_exists($filepath)) { @unlink($filepath); }
        $db->prepare("DELETE FROM playlist_songs WHERE song_id = ?")->execute([(int)$_POST['id']]);
        $db->prepare("DELETE FROM songs WHERE id = ?")->execute([(int)$_POST['id']]);
        echo json_encode(['status' => 'deleted']);
    } else { echo json_encode(['status' => 'error', 'message' => 'Song not found']); }
    exit;
}
$allowed = ['mp3', 'ogg', 'flac', 'wav', 'm4a', 'aac'];
$maxSize = 20 * 1024 * 1024;
$uploaded = []; $errors = [];
if (isset($_FILES['files'])) { $files = $_FILES['files']; }
elseif (isset($_FILES['audio_file'])) { $files = ['name' => [$_FILES['audio_file']['name']], 'tmp_name' => [$_FILES['audio_file']['tmp_name']], 'size' => [$_FILES['audio_file']['size']], 'error' => [$_FILES['audio_file']['error']]]; }
else { echo json_encode(['error' => 'No files uploaded']); exit; }
$count = count($files['name']);
for ($i = 0; $i < $count; $i++) {
    if ($files['error'][$i] !== UPLOAD_ERR_OK) { $errors[] = "File " . ($i+1) . ": Upload error"; continue; }
    $filename = $files['name'][$i]; $tmp_name = $files['tmp_name'][$i]; $file_size = $files['size'][$i];
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    if (!in_array($ext, $allowed)) { $errors[] = "File " . ($i+1) . ": Invalid file type ($ext)"; continue; }
    if ($file_size > $maxSize) { $errors[] = "File " . ($i+1) . ": File too large (max 20MB)"; continue; }
    if ($file_size == 0) { $errors[] = "File " . ($i+1) . ": Empty file"; continue; }
    $newFilename = bin2hex(random_bytes(16)) . '.' . $ext; $destination = MUSIC_DIR . '/' . $newFilename;
    if (move_uploaded_file($tmp_name, $destination)) {
        $db = new PDO('sqlite:' . DB_PATH);
        $stmt = $db->prepare("INSERT INTO songs (filename, original_name, title, artist) VALUES (?, ?, ?, ?)");
        $stmt->execute([$newFilename, preg_replace('/[^a-zA-Z0-9._-]/', '_', $filename), $_POST['title'] ?? '', $_POST['artist'] ?? '']);
        $uploaded[] = ['id' => $db->lastInsertId(), 'name' => $filename];
    } else { $errors[] = "File " . ($i+1) . ": Failed to save"; }
}
$result = [];
if (count($uploaded) > 0) {
    $result['success'] = true;
    $result['uploaded'] = $uploaded;
    $pidFile = '/var/run/airbone/autodj.pid';
    $running = false;
    if (file_exists($pidFile)) {
        $pid = trim(file_get_contents($pidFile));
        if ($pid && (function_exists('posix_getpgid') ? @posix_getpgid((int)$pid) : file_exists("/proc/$pid"))) { $running = true; }
    }
    if (!$running) {
        $liqResult = generateLiquidsoapScript();
        $liqBin = escapeshellarg(getLiquidsoapBinary());
        @file_put_contents('/var/www/airbone/autodj.liq', $liqResult['script']);
        @chmod('/var/www/airbone/autodj.liq', 0644);
        @mkdir('/var/log/airbone', 0755, true);
        @shell_exec("pkill -f 'liquidsoap' 2>/dev/null");
        @shell_exec("cd /var/www/airbone && nohup {$liqBin} autodj.liq > /var/log/airbone/autodj.log 2>&1 &");
        sleep(2);
        $newPid = trim(@shell_exec("pgrep -f 'liquidsoap' | head -1"));
        if ($newPid) {
            @file_put_contents($pidFile, $newPid);
            $result['autodj_started'] = true;
            $result['format'] = $liqResult['format'];
            $result['bitrate'] = $liqResult['bitrate'];
        }
    }
}
if (count($errors) > 0) { $result['errors'] = $errors; }
echo json_encode($result);
UPLOADEOF
    log "API endpoints created"
}

create_css() {
    log "Creating CSS styles..."

    cat > "$RADIO_DIR/app/css/style.css" << 'CSSEOF'
:root { --bg-primary: #2c3e50; --bg-secondary: #34495e; --bg-card: #3d566e; --neon-orange: #ff6600; --neon-orange-light: #ff8533; --lime-green: #32cd32; --lime-green-light: #7cfc00; --text-primary: #ecf0f1; --text-secondary: #bdc3c7; --danger: #e74c3c; --warning: #f39c12; --success: #27ae60; --border-radius: 16px; }
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: var(--bg-primary); color: var(--text-primary); min-height: 100vh; }
.container { display: flex; min-height: 100vh; }
.sidebar { width: 250px; background: var(--bg-secondary); padding: 20px; border-radius: 0 var(--border-radius) var(--border-radius) 0; }
.logo { text-align: center; padding: 20px 0; margin-bottom: 30px; }
.logo h2 { color: var(--neon-orange); font-size: 24px; text-transform: uppercase; letter-spacing: 2px; text-shadow: 0 0 10px var(--neon-orange); }
.nav-menu { list-style: none; }
.nav-menu li { margin-bottom: 8px; }
.nav-menu a { display: block; padding: 12px 16px; color: var(--lime-green); text-decoration: none; border-radius: var(--border-radius); transition: all 0.3s ease; font-weight: 500; border: 2px solid transparent; }
.nav-menu a:hover, .nav-menu li.active a { background: var(--neon-orange); color: var(--bg-primary); border-color: var(--neon-orange); box-shadow: 0 0 20px var(--neon-orange); }
.content { flex: 1; padding: 30px; overflow-y: auto; }
header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 30px; padding-bottom: 20px; border-bottom: 2px solid var(--bg-card); }
header h1 { color: var(--lime-green); font-size: 28px; text-shadow: 0 0 10px var(--lime-green); }
.card { background: var(--bg-card); border-radius: var(--border-radius); padding: 25px; margin-bottom: 20px; border: 3px solid var(--neon-orange); box-shadow: 0 0 15px rgba(255, 102, 0, 0.3); }
.card h3 { color: var(--lime-green); margin-bottom: 15px; font-size: 18px; }
.dashboard-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; }
.status-indicator { display: flex; align-items: center; gap: 15px; margin: 15px 0; }
.status-dot { width: 16px; height: 16px; border-radius: 50%; animation: pulse 2s infinite; }
.status-dot.online { background: var(--lime-green); box-shadow: 0 0 15px var(--lime-green); }
.status-dot.offline { background: var(--danger); box-shadow: 0 0 15px var(--danger); }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
.controls { display: flex; gap: 10px; flex-wrap: wrap; }
.btn { padding: 10px 20px; border: none; border-radius: var(--border-radius); cursor: pointer; font-size: 14px; font-weight: 600; transition: all 0.3s ease; text-decoration: none; display: inline-block; }
.btn-primary { background: var(--neon-orange); color: var(--bg-primary); }
.btn-primary:hover { background: var(--neon-orange-light); box-shadow: 0 0 20px var(--neon-orange); }
.btn-success { background: var(--success); color: white; }
.btn-success:hover { box-shadow: 0 0 20px var(--success); }
.btn-danger { background: var(--danger); color: white; }
.btn-danger:hover { box-shadow: 0 0 20px var(--danger); }
.btn-warning { background: var(--warning); color: var(--bg-primary); }
.btn-warning:hover { box-shadow: 0 0 20px var(--warning); }
.btn-small { padding: 6px 12px; font-size: 12px; }
.btn-icon { background: transparent; border: 2px solid var(--lime-green); color: var(--lime-green); width: 30px; height: 30px; border-radius: 8px; cursor: pointer; transition: all 0.3s ease; }
.btn-icon:hover { background: var(--lime-green); color: var(--bg-primary); }
.stat { text-align: center; padding: 15px; }
.stat-value { display: block; font-size: 40px; font-weight: bold; color: var(--lime-green); text-shadow: 0 0 10px var(--lime-green); }
.stat-label { display: block; color: var(--text-secondary); font-size: 12px; margin-top: 5px; }
.now-playing-card .track-title { font-size: 24px; color: var(--lime-green); margin-bottom: 10px; }
.now-playing-card .track-artist { font-size: 16px; color: var(--text-secondary); }
.now-playing-card .btn { margin-top: 10px; }
.quick-actions { display: flex; gap: 10px; flex-wrap: wrap; }
.login-container { display: flex; justify-content: center; align-items: center; min-height: 100vh; background: var(--bg-primary); }
.login-card { width: 100%; max-width: 380px; text-align: center; }
.login-card h1 { color: var(--neon-orange); font-size: 32px; margin-bottom: 10px; text-shadow: 0 0 15px var(--neon-orange); }
.login-card h2 { color: var(--lime-green); margin-bottom: 20px; }
.form-group { margin-bottom: 18px; text-align: left; }
.form-group label { display: block; color: var(--lime-green); margin-bottom: 6px; font-weight: 500; }
.form-group input, .form-group textarea, .form-group select { width: 100%; padding: 10px 14px; border: 2px solid var(--bg-secondary); border-radius: var(--border-radius); background: var(--bg-secondary); color: var(--text-primary); font-size: 14px; transition: border-color 0.3s; }
.form-group input:focus, .form-group textarea:focus, .form-group select:focus { outline: none; border-color: var(--neon-orange); box-shadow: 0 0 10px rgba(255, 102, 0, 0.3); }
table { width: 100%; border-collapse: collapse; }
table th, table td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--bg-secondary); }
table th { color: var(--lime-green); font-weight: 600; }
table tr:hover { background: rgba(255, 102, 0, 0.1); }
.empty-state { text-align: center; color: var(--text-secondary); padding: 30px 20px !important; }
.alert { padding: 12px 16px; border-radius: var(--border-radius); margin-bottom: 15px; }
.alert.error { background: rgba(231, 76, 60, 0.2); border: 2px solid var(--danger); color: var(--danger); }
.alert.success { background: rgba(39, 174, 96, 0.2); border: 2px solid var(--success); color: var(--success); }
.playlists-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 20px; }
.playlist-card { display: flex; flex-direction: column; }
.playlist-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
.playlist-header h3 { margin-bottom: 0; }
.song-count { color: var(--text-secondary); font-size: 12px; }
.playlist-desc { color: var(--text-secondary); margin-bottom: 12px; font-size: 13px; }
.playlist-actions { display: flex; gap: 8px; margin-bottom: 12px; }
.playlist-songs { border-top: 1px solid var(--bg-secondary); padding-top: 12px; }
.playlist-songs h4 { color: var(--lime-green); margin-bottom: 8px; }
.playlist-songs ul { list-style: none; margin-bottom: 12px; }
.playlist-songs li { padding: 6px 0; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--bg-secondary); }
.add-song-form { display: flex; flex-direction: column; gap: 8px; }
.add-song-form select { flex: 1; padding: 8px; border: 2px solid var(--bg-secondary); border-radius: 8px; background: var(--bg-secondary); color: var(--text-primary); }
.multi-select-wrapper { width: 100%; }
.multi-select { width: 100%; min-height: 120px; padding: 8px; border: 2px solid var(--lime-green); border-radius: 8px; background: var(--bg-secondary); color: var(--text-primary); font-size: 13px; }
.multi-select option { padding: 6px 8px; border-bottom: 1px solid var(--bg-primary); }
.multi-select option:hover { background: var(--neon-orange); color: var(--bg-primary); }
.badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 11px; font-weight: 600; margin-right: 6px; margin-bottom: 6px; }
.badge-general { background: rgba(50, 205, 50, 0.2); border: 1px solid var(--lime-green); color: var(--lime-green); }
.badge-songs { background: rgba(255, 102, 0, 0.2); border: 1px solid var(--neon-orange); color: var(--neon-orange); }
.badge-minutes { background: rgba(243, 156, 18, 0.2); border: 1px solid var(--warning); color: var(--warning); }
.badge-hour { background: rgba(52, 152, 219, 0.2); border: 1px solid #3498db; color: #3498db; }
.badge-order { background: rgba(189, 195, 199, 0.15); border: 1px solid var(--text-secondary); color: var(--text-secondary); }
.playlist-badges { margin-bottom: 8px; }
.edit-form { border-top: 1px solid var(--bg-secondary); padding-top: 12px; margin-top: 12px; margin-bottom: 12px; }
.edit-form .form-group { margin-bottom: 10px; }
.edit-form label { font-size: 12px; }
.edit-form input, .edit-form textarea, .edit-form select { font-size: 13px; }
.form-help { display: block; color: var(--text-secondary); font-size: 11px; margin-top: 4px; }
.settings-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; }
.info-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid var(--bg-secondary); }
.info-label { color: var(--text-secondary); }
.info-value { color: var(--lime-green); font-family: monospace; }
.upload-form { margin-bottom: 25px; }
.library-list { overflow-x: auto; }
@media (max-width: 768px) { .container { flex-direction: column; } .sidebar { width: 100%; border-radius: 0 0 var(--border-radius) var(--border-radius); } .dashboard-grid, .playlists-grid, .settings-grid { grid-template-columns: 1fr; } }
CSSEOF
    log "CSS styles created"
}

create_javascript() {
    log "Creating JavaScript..."

    cat > "$RADIO_DIR/app/js/main.js" << 'JSEOF'
async function apiCall(endpoint, method) {
    if (!method) method = 'GET';
    try {
        var r = await fetch('api/' + endpoint, { method: method, headers: { 'Content-Type': 'application/json' } });
        return await r.json();
    } catch (e) {
        return { error: e.message };
    }
}

async function updateStatus() {
    var np = await apiCall('nowplaying.php');
    var ls = await apiCall('listeners.php');
    var se = document.getElementById('autodj-status');
    var te = document.getElementById('autodj-text');
    var t1 = document.querySelector('.track-title');
    var t2 = document.querySelector('.track-artist');
    var le = document.getElementById('listener-count');
    if (se) se.className = 'status-dot ' + (np && np.autodj_status === 'running' ? 'online' : 'offline');
    if (te) te.textContent = np && np.autodj_status === 'running' ? 'Running' : 'Offline';
    if (t1 && np) t1.textContent = np.title || 'No track playing';
    if (t2 && np) t2.textContent = np.artist || '-';
    if (le && ls) le.textContent = ls.listeners || 0;
}

document.addEventListener('DOMContentLoaded', function() {
    ['btn-start', 'btn-stop', 'btn-skip'].forEach(function(id) {
        var btn = document.getElementById(id);
        if (btn) btn.addEventListener('click', async function() {
            var ep = id === 'btn-start' ? 'start.php' : id === 'btn-stop' ? 'stop.php' : 'skip.php';
            btn.disabled = true;
            btn.textContent = 'Loading...';
            var r = await apiCall(ep, 'POST');
            if (id === 'btn-start') {
                if (r.status === 'started') alert('AutoDJ Started!\nFormat: ' + (r.format || 'MP3') + '\nBitrate: ' + (r.bitrate || 128) + ' kbps\nSongs: ' + (r.songs || 0));
                else if (r.status === 'already_running') alert('AutoDJ is already running!');
                else alert('Error: ' + (r.message || 'Failed to start'));
            } else if (id === 'btn-stop') {
                alert(r.status === 'stopped' ? 'AutoDJ Stopped' : 'Failed to stop');
            } else if (id === 'btn-skip') {
                alert(r.status === 'skipped' ? 'Track Skipped!' : 'Failed to skip');
            }
            btn.disabled = false;
            btn.textContent = btn.id === 'btn-start' ? 'Start' : btn.id === 'btn-stop' ? 'Stop' : 'Skip';
            updateStatus();
        });
    });
});

async function deleteSong(id) {
    if (confirm('Delete this song?')) {
        var f = new FormData();
        f.append('action', 'delete');
        f.append('id', id);
        await fetch('api/upload.php', { method: 'POST', body: f });
        location.reload();
    }
}
JSEOF
    log "JavaScript created"
}

create_scripts() {
    log "Creating service scripts..."

    cat > "$RADIO_DIR/scripts/start.sh" << 'STARTEOF'
#!/bin/bash
mkdir -p /var/run/airbone /var/log/airbone
LIQ_BIN="$(command -v liquidsoap 2>/dev/null || true)"
if [ -z "$LIQ_BIN" ]; then LIQ_BIN="/usr/bin/liquidsoap"; fi
nohup "$LIQ_BIN" /var/www/airbone/autodj.liq > /var/log/airbone/autodj.log 2>&1 &
echo $! > /var/run/airbone/autodj.pid
echo "AutoDJ started with PID $(cat /var/run/airbone/autodj.pid)"
STARTEOF

    cat > "$RADIO_DIR/scripts/stop.sh" << 'STOPEOF'
#!/bin/bash
pkill -f 'liquidsoap' 2>/dev/null
rm -f /var/run/airbone/autodj.pid
echo "AutoDJ stopped"
STOPEOF

    cat > "$RADIO_DIR/scripts/restart.sh" << 'RESTARTEOF'
#!/bin/bash
/var/www/airbone/scripts/stop.sh
sleep 2
/var/www/airbone/scripts/start.sh
RESTARTEOF

    chmod +x "$RADIO_DIR/scripts/"*.sh
    log "Service scripts created"
}

configure_permissions() {
    log "Configuring permissions..."
    chown -R www-data:www-data "$RADIO_DIR"
    chmod -R 755 "$RADIO_DIR"
    chmod -R 775 "$RADIO_DIR/music" "$RADIO_DIR/jingles" "$RADIO_DIR/playlists"
    chmod 644 "$RADIO_DIR/airbone.db"
    log "Permissions configured"
}

restart_services() {
    log "Starting all services..."
    
    mkdir -p /var/run/airbone /var/log/airbone
    chown -R www-data:www-data /var/run/airbone /var/log/airbone "$RADIO_DIR" 2>/dev/null || true
    
    log "Stopping existing services..."
    pkill -f 'liquidsoap' 2>/dev/null || true
    service lighttpd stop 2>/dev/null || true
    sleep 1
    
    log "Starting PHP-FPM..."
    for svc in php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
        if systemctl list-unit-files | grep -q "$svc"; then
            systemctl enable $svc 2>/dev/null || true
            systemctl restart $svc 2>/dev/null || true
        fi
    done
    service php*-fpm restart 2>/dev/null || true
    sleep 2
    
    log "Starting Icecast..."
    service icecast2 stop 2>/dev/null || true
    service icecast2 start 2>/dev/null || true
    sleep 2
    
    log "Starting Lighttpd..."
    rm -f /etc/lighttpd/conf-enabled/15-fastcgi*.conf 2>/dev/null || true
    rm -f /etc/lighttpd/conf-enabled/90-upload.conf 2>/dev/null || true
    ln -sf /etc/lighttpd/conf-available/15-airbone.conf /etc/lighttpd/conf-enabled/15-airbone.conf 2>/dev/null || true
    service lighttpd start 2>/dev/null || systemctl start lighttpd 2>/dev/null || true
    sleep 2
    
    if pgrep -x lighttpd > /dev/null; then
        log "Lighttpd is running"
    else
        log "Warning: Lighttpd may not be running"
    fi
    
    if pgrep -x icecast2 > /dev/null; then
        log "Icecast is running on port 8000"
    else
        log "Warning: Icecast may not be running"
    fi
    
    log "All services started"
}

main() {
    echo ""
    echo "=============================================="
    echo "     AirBoneRadio Installation"
    echo "=============================================="
    echo ""
    log "=== Installation Started ==="
    
    check_root
    detect_os
    install_dependencies
    create_directory_structure
    setup_php_upload
    setup_lighttpd
    setup_icecast
    create_liquidsoap_script
    setup_initial_user
    create_php_files
    create_pages
    create_dashboard
    create_library
    create_playlists
    create_settings
    create_player
    create_api
    create_css
    create_javascript
    create_scripts
    configure_permissions
    restart_services

    echo ""
    echo "=============================================="
    echo "     Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Admin Credentials:"
    echo "  Username: $ADMIN_USER"
    echo "  Password: $ADMIN_PASS"
    echo ""
    echo "Access the control panel at:"
    echo "  http://localhost/radio/"
    echo ""
    echo "Stream URL:"
    echo "  http://localhost:8000/stream"
    echo ""
    echo "=== Service Status ==="
    echo -n "Lighttpd: "; (pgrep -x lighttpd > /dev/null && echo "Running" || echo "Not running")
    echo -n "PHP-FPM: "; (pgrep -a php-fpm | head -1 | cut -d' ' -f1-3 || echo "Not running")
    echo -n "Icecast: "; (pgrep -x icecast2 > /dev/null && echo "Running" || echo "Not running")
    echo ""
    echo "=============================================="
    echo ""
    log "=== Installation Complete ==="
}

main "$@"
