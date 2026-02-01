#!/usr/bin/env python3
"""
Pre-populate Anki's prefs21.db with AnkiWeb credentials.

This script sets up the sync credentials before Anki's first run,
allowing automatic sync without user interaction.

Usage:
    ANKIWEB_USERNAME=user@example.com ANKIWEB_PASSWORD=secret ./setup-ankiweb-credentials.py

The script will:
1. Create prefs21.db if it doesn't exist
2. Create a default profile if needed
3. Set the syncKey (hkey) and syncUser fields
"""

import sqlite3
import pickle
import hashlib
import os
import sys
import time
import random

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


def generate_hkey(username: str, password: str) -> str:
    """Generate the sync authentication key (hkey) from credentials."""
    # The hkey is hex(sha1("username:password"))
    auth_string = f"{username}:{password}"
    return hashlib.sha1(auth_string.encode("utf-8")).hexdigest()


def setup_credentials(username: str, password: str) -> bool:
    """Set up AnkiWeb credentials in the prefs database."""

    # Ensure directory exists
    os.makedirs(ANKI_DATA_DIR, exist_ok=True)

    # Generate the hkey
    hkey = generate_hkey(username, password)
    print(f"Generated hkey for {username}")

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
        print("Creating new _global profile")

    # Ensure last_loaded_profile_name is set
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

    # Set sync credentials
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

    print(f"Successfully configured AnkiWeb credentials in {PREFS_DB_PATH}")
    print(f"  Username: {username}")
    print(f"  Profile: {PROFILE_NAME}")
    print(f"  Auto-sync: enabled")

    return True


def main():
    # Get credentials from environment
    username = os.environ.get("ANKIWEB_USERNAME", "").strip()
    password = os.environ.get("ANKIWEB_PASSWORD", "").strip()

    if not username or not password:
        print("AnkiWeb credentials not provided (ANKIWEB_USERNAME and/or ANKIWEB_PASSWORD not set)")
        print("Skipping AnkiWeb credential setup - user will need to log in manually")
        sys.exit(0)

    try:
        setup_credentials(username, password)
    except Exception as e:
        print(f"Error setting up AnkiWeb credentials: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
