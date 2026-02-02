#!/usr/bin/env python3
"""
Pre-populate Anki's prefs21.db with profile settings and optional AnkiWeb credentials.

This script sets up the Anki profile before the first run to:
1. Skip the first-run wizard (locale selection dialog)
2. Create a default user profile
3. Optionally configure AnkiWeb sync credentials

Usage:
    # Always run to set up profile (required to skip first-run wizard):
    ./setup-ankiweb-credentials.py

    # With AnkiWeb credentials for automatic sync:
    ANKIWEB_USERNAME=user@example.com ANKIWEB_PASSWORD=secret ./setup-ankiweb-credentials.py

The script will:
1. Create prefs21.db if it doesn't exist
2. Create _global profile with firstRun=False to skip locale dialog
3. Create a default user profile
4. Set syncKey (hkey) and syncUser fields if credentials are provided
"""

import sqlite3
import pickle
import os
import sys
import time
import random
import json
import io
import urllib.request
import urllib.parse
import urllib.error

try:
    import zstandard as zstd
    HAS_ZSTD = True
except ImportError:
    HAS_ZSTD = False

# Configuration
ANKI_DATA_DIR = os.path.expanduser("~/anki/anki_data/.local/share/Anki2")
PREFS_DB_PATH = os.path.join(ANKI_DATA_DIR, "prefs21.db")
PROFILE_NAME = "User 1"

# Default profile configuration (based on Anki's profileConf)
DEFAULT_GLOBAL_PROFILE = {
    "created": int(time.time()),
    "defaultLang": "en_US",
    "firstRun": False,
    "id": random.randint(1000000000000000000, 9999999999999999999),
    "lastMsg": 0,
    "last_loaded_profile_name": PROFILE_NAME,
    "last_run_version": 250204,
    "suppressUpdate": False,
    "updates": True,
    "ver": 0,
}

DEFAULT_USER_PROFILE = {
    "mainWindowGeom": None,
    "mainWindowState": None,
    "numBackups": 50,
    "lastOptimize": int(time.time()),
    "searchHistory": [],
    "syncKey": None,
    "syncMedia": True,
    "autoSync": True,
    "allowHTML": False,
    "importMode": 1,
    "lastColour": "#00f",
    "stripHTML": True,
    "deleteMedia": False,
}


def get_hkey_from_ankiweb(username: str, password: str) -> str:
    """
    Get the sync authentication key (hkey) from AnkiWeb server.

    The hkey is a server-generated token returned by AnkiWeb's hostKey endpoint.
    This is the only way to obtain a valid sync key - it cannot be generated locally.

    Uses the modern Anki sync protocol with zstd compression if available.
    """
    url = "https://sync.ankiweb.net/sync/hostKey"
    # AnkiWeb expects JSON body with "u" and "p" fields
    json_data = json.dumps({"u": username, "p": password}).encode("utf-8")

    if HAS_ZSTD:
        # Modern protocol: zstd-compressed body with anki-sync header
        compressor = zstd.ZstdCompressor()
        data = compressor.compress(json_data)

        request = urllib.request.Request(url, data=data, method="POST")
        request.add_header("Content-Type", "application/octet-stream")
        # Header format: v=version, k=key (empty for login), c=client version, s=session
        sync_header = json.dumps({"v": 11, "k": "", "c": "anki,2.1.65", "s": "setup"})
        request.add_header("anki-sync", sync_header)
    else:
        # Fallback: plain JSON (may not work with newer AnkiWeb servers)
        data = json_data
        request = urllib.request.Request(url, data=data, method="POST")
        request.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response_data = response.read()
            if HAS_ZSTD:
                # Try to decompress zstd response, fall back to plain if it fails
                try:
                    decompressor = zstd.ZstdDecompressor()
                    # Use streaming decompression which doesn't require frame size
                    reader = decompressor.stream_reader(io.BytesIO(response_data))
                    response_data = reader.read()
                except Exception:
                    # Response might not be compressed, try as-is
                    pass
            result = json.loads(response_data.decode("utf-8"))
            if "key" not in result:
                raise ValueError(f"Unexpected response from AnkiWeb: {result}")
            return result["key"]
    except urllib.error.HTTPError as e:
        if e.code == 401 or e.code == 403:
            raise ValueError("Invalid AnkiWeb username or password") from e
        raise ValueError(f"AnkiWeb request failed with status {e.code}") from e
    except urllib.error.URLError as e:
        raise ValueError(f"Failed to connect to AnkiWeb: {e.reason}") from e


def setup_profile(username: str = None, password: str = None) -> bool:
    """
    Set up Anki profile in the prefs database.

    Always creates _global profile (with firstRun=False) and user profile.
    If credentials are provided, also configures AnkiWeb sync.
    """

    # Ensure directory exists
    os.makedirs(ANKI_DATA_DIR, exist_ok=True)

    # Connect to database (creates if doesn't exist)
    conn = sqlite3.connect(PREFS_DB_PATH)
    cursor = conn.cursor()

    # Create table if it doesn't exist
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS profiles
        (name text primary key collate nocase, data blob not null)
    """)

    # Check if _global profile exists
    cursor.execute("SELECT data FROM profiles WHERE name = '_global'")
    row = cursor.fetchone()

    if row:
        global_profile = pickle.loads(row[0])
        print("Found existing _global profile")
    else:
        global_profile = DEFAULT_GLOBAL_PROFILE.copy()
        print("Creating new _global profile with firstRun=False")

    # Ensure critical settings are set
    global_profile["firstRun"] = False
    global_profile["defaultLang"] = "en_US"
    global_profile["last_loaded_profile_name"] = PROFILE_NAME

    # Save _global profile
    cursor.execute(
        "INSERT OR REPLACE INTO profiles (name, data) VALUES (?, ?)",
        ("_global", pickle.dumps(global_profile))
    )

    # Check if user profile exists
    cursor.execute("SELECT data FROM profiles WHERE name = ?", (PROFILE_NAME,))
    row = cursor.fetchone()

    if row:
        user_profile = pickle.loads(row[0])
        print(f"Found existing '{PROFILE_NAME}' profile")
    else:
        user_profile = DEFAULT_USER_PROFILE.copy()
        print(f"Creating new '{PROFILE_NAME}' profile")

    # Set sync credentials if provided
    if username and password:
        print(f"Authenticating with AnkiWeb as {username}...")
        hkey = get_hkey_from_ankiweb(username, password)
        print(f"Successfully obtained hkey from AnkiWeb")
        user_profile["syncKey"] = hkey
        user_profile["syncUser"] = username
        user_profile["autoSync"] = True
        user_profile["syncMedia"] = True

    # Save user profile
    cursor.execute(
        "INSERT OR REPLACE INTO profiles (name, data) VALUES (?, ?)",
        (PROFILE_NAME, pickle.dumps(user_profile))
    )

    conn.commit()
    conn.close()

    print(f"Successfully configured Anki profile in {PREFS_DB_PATH}")
    print(f"  Profile: {PROFILE_NAME}")
    print(f"  firstRun: False (will skip locale dialog)")
    if username:
        print(f"  AnkiWeb username: {username}")
        print(f"  Auto-sync: enabled")
    else:
        print(f"  AnkiWeb: not configured (user can log in manually)")

    return True


def main():
    # Get credentials from environment (optional)
    username = os.environ.get("ANKIWEB_USERNAME", "").strip()
    password = os.environ.get("ANKIWEB_PASSWORD", "").strip()

    # Only use credentials if both are provided
    if not username or not password:
        username = None
        password = None
        print("AnkiWeb credentials not provided - profile will be created without sync credentials")

    try:
        setup_profile(username, password)
    except Exception as e:
        print(f"Error setting up Anki profile: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
