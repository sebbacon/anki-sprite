#!/usr/bin/env node
/**
 * REST API proxy for AnkiConnect
 * Translates REST-style endpoints to AnkiConnect's JSON-RPC format
 */

const http = require('http');

const ANKI_CONNECT_URL = 'http://localhost:8765';
const PORT = 8767;

// Map REST endpoints to AnkiConnect actions
const ENDPOINT_MAP = {
  'GET /deckNames': { action: 'deckNames' },
  'POST /createDeck': { action: 'createDeck', paramKey: 'deck' },
  'GET /modelNames': { action: 'modelNames' },
  'POST /modelFieldNames': { action: 'modelFieldNames', paramKey: 'modelName' },
  'POST /addNote': { action: 'addNote', paramKey: 'note' },
  'POST /addNotes': { action: 'addNotes', paramKey: 'notes' },
  'POST /findNotes': { action: 'findNotes', paramKey: 'query' },
  'POST /notesInfo': { action: 'notesInfo', paramKey: 'notes' },
  'POST /updateNoteFields': { action: 'updateNoteFields', paramKey: 'note' },
  'POST /deleteNotes': { action: 'deleteNotes', paramKey: 'notes' },
  'POST /sync': { action: 'sync' },
};

async function callAnkiConnect(action, params = {}) {
  const body = JSON.stringify({ action, version: 6, params });
  return new Promise((resolve, reject) => {
    const req = http.request(ANKI_CONNECT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(new Error('Invalid JSON from AnkiConnect')); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      if (!body) return resolve({});
      try { resolve(JSON.parse(body)); }
      catch (e) { reject(new Error('Invalid JSON in request body')); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key, Authorization');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  if (path === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }

  if (path === '/openapi.json') {
    try {
      const fs = require('fs');
      const spec = fs.readFileSync('/home/sprite/anki/openapi-anki.json', 'utf8');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(spec);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Failed to load OpenAPI spec' }));
    }
    return;
  }

  const endpointKey = `${req.method} ${path}`;
  const endpoint = ENDPOINT_MAP[endpointKey];

  if (!endpoint) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: `Unknown endpoint: ${endpointKey}` }));
    return;
  }

  try {
    let params = {};
    if (req.method === 'POST') {
      const body = await parseBody(req);
      if (endpoint.paramKey) {
        params = { [endpoint.paramKey]: body[endpoint.paramKey] || body };
      } else {
        params = body;
      }
    }
    const result = await callAnkiConnect(endpoint.action, params);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
  } catch (e) {
    if (e.code === 'ECONNREFUSED' || e.code === 'ENOTFOUND' || e.code === 'ETIMEDOUT') {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: 'AnkiConnect is not available. Anki may still be starting up.',
        status: 'unavailable',
        code: 503
      }));
    } else {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message || 'Unknown error occurred' }));
    }
  }
});

server.listen(PORT, () => {
  console.log(`Anki REST API proxy listening on port ${PORT}`);
  console.log(`OpenAPI spec available at http://localhost:${PORT}/openapi.json`);
});
