// Leave empty when the UI and API are served from the same host (k3s ingress, docker compose).
// On Netlify, set this to your API URL, e.g. "https://api.yourdomain.com".
window.API_BASE = "";
// The Netlify build (scripts/netlify-build.py) replaces this file and sets window.SHOWCASE = { taken, live }.
window.SHOWCASE = null;
