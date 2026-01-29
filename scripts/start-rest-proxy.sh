#!/bin/bash
# Anki REST API proxy startup script

cd /home/sprite/anki

# Source nvm to get correct PATH
export NVM_DIR="/.sprite/languages/node/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

exec node /home/sprite/anki/anki-rest-proxy.js
