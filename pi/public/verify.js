// Public chat (Phase 9b), runs inside nginx on the Pi (njs). Netlify signs every request it proxies here
// with a secret we share (netlify.toml: signed = "QWENOPS_PROXY_SECRET"): header X-Nf-Sign holds a JWS
// (HS256). Only requests with a valid, unexpired signature from Netlify get through; anyone calling the
// public Funnel address directly is refused (403).
const fs = require('fs');
const crypto = require('crypto');

const SECRET_FILE = '/etc/qwenops-gateway/public/netlify.secret';

function sameText(a, b) {   // compare without stopping at the first difference
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

function verify(r) {
    const token = r.headersIn['X-Nf-Sign'] || '';
    const parts = token.split('.');
    if (parts.length !== 3) return '0';
    let secret;
    try { secret = fs.readFileSync(SECRET_FILE, 'utf8').trim(); } catch (e) { return '0'; }
    if (!secret) return '0';
    const expected = crypto.createHmac('sha256', secret).update(parts[0] + '.' + parts[1]).digest('base64url');
    if (!sameText(expected, parts[2])) return '0';
    let header, claims;
    try {
        header = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
        claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
    } catch (e) { return '0'; }
    if (header.alg !== 'HS256' || claims.iss !== 'netlify') return '0';
    if (typeof claims.exp === 'number' && claims.exp < Date.now() / 1000) return '0';
    return '1';
}

export default { verify };
