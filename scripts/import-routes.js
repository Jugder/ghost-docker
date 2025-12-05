#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const GhostAdminAPI = require('@tryghost/admin-api');
const yaml = require('js-yaml');

const ROUTES_PATH = process.env.ROUTES_PATH || path.join(__dirname, '..', 'data', 'ghost', 'settings', 'routes.yaml');
const SITE_URL = (process.env.GHOST_URL || process.env.GHOST_ADMIN_URL || 'http://localhost:2368').replace(/\/$/, '');
const ADMIN_KEY = process.env.GHOST_ADMIN_API_KEY || process.env.GHOST_ADMIN_KEY;

if (!ADMIN_KEY) {
  console.error('Missing GHOST_ADMIN_API_KEY (format: <id>:<secret>). Set env and retry.');
  console.error('Example: GHOST_ADMIN_API_KEY="<id>:<secret>" GHOST_URL="https://example.com" node import-routes.js');
  process.exit(2);
}

let routesYml;
try {
  routesYml = fs.readFileSync(ROUTES_PATH, 'utf8');
} catch (err) {
  console.error('Failed to read routes file:', ROUTES_PATH);
  console.error(err.message || err);
  process.exit(2);
}

const api = new GhostAdminAPI({
  url: SITE_URL,
  key: ADMIN_KEY,
  version: 'v5.0'
});

// Debug: inspect available api keys to diagnose missing settings helper
console.log('api keys:', Object.keys(api));
console.log('api.settings type:', typeof api.settings);
console.log('api.site keys:', Object.keys(api.site || {}));
console.log('api.config keys:', Object.keys(api.config || {}));

(async () => {
  try {
    console.log('Importing routes from', ROUTES_PATH, 'to', SITE_URL);
    const res = await api.settings.edit({routes: routesYml});
    console.log('Import successful. Updated settings:');
    console.log(JSON.stringify(res, null, 2));
  } catch (err) {
    console.error('Import failed:');
    if (err && err.response && err.response.data) {
      console.error(JSON.stringify(err.response.data, null, 2));
    } else {
      console.error(err.message || err);
    }
    process.exit(3);
  }
})();
