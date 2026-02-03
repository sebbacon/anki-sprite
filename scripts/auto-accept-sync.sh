#!/bin/bash
# Auto-accept Anki's initial sync dialog
# This script watches for the "Full Sync" dialog and clicks Download
# Run with DISPLAY=:1 set

DISPLAY="${DISPLAY:-:1}"
export DISPLAY

echo "Auto-accept sync watcher started on display $DISPLAY"

# Wait for the sync dialog to appear and auto-accept it
# The dialog window typically contains "Download" and "Upload" buttons
# We want to click Download (or press Enter if it's the default)

MAX_WAIT=120  # Wait up to 2 minutes for the dialog
FOUND=false

for i in $(seq 1 $MAX_WAIT); do
    # Look for Anki dialog windows
    # The sync dialog has title "Anki" (not "User 1 - Anki" like the main window)
    # Search for all windows with "Anki" in the name
    for WINDOW_ID in $(xdotool search --name "Anki" 2>/dev/null); do
        WINDOW_NAME=$(xdotool getwindowname "$WINDOW_ID" 2>/dev/null)

        # Skip the main Anki window (contains " - Anki")
        if echo "$WINDOW_NAME" | grep -q " - Anki"; then
            continue
        fi

        # Found a dialog window (title is exactly "Anki")
        if [ "$WINDOW_NAME" = "Anki" ]; then
            echo "Found sync dialog: $WINDOW_NAME (ID: $WINDOW_ID)"

            # Focus the window and send Enter (Yes/Download is typically default)
            xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null
            sleep 0.5

            # Send Enter key to accept the default
            xdotool key Return
            echo "Sent Enter key to accept sync dialog"
            FOUND=true
            break 2  # Break out of both loops
        fi
    done

    sleep 1
done

if [ "$FOUND" = false ]; then
    echo "No sync dialog appeared within ${MAX_WAIT}s (this is normal if collection is in sync)"
fi

echo "Auto-accept sync watcher finished"
