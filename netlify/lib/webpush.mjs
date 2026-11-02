// Web Push (RFC 8291 message encryption and RFC 8292 VAPID), using only Node's built-in crypto.
// Phones subscribe in the app; the server encrypts each message for that one phone and posts it
// to the phone maker's push service (Apple, Google or Mozilla), which delivers it.
import crypto from "node:crypto";

const b64u = (buf) => Buffer.from(buf).toString("base64url");
const unb64u = (s) => Buffer.from(String(s), "base64url");

// A new VAPID key pair: the public key goes to the phones, the private key signs every send.
export function generateVapidKeys() {
  const ecdh = crypto.createECDH("prime256v1");
  ecdh.generateKeys();
  const d = ecdh.getPrivateKey();
  return { publicKey: b64u(ecdh.getPublicKey()), privateKey: b64u(Buffer.concat([Buffer.alloc(32 - d.length), d])) };
}

function vapidHeader(endpoint, vapid) {
  const aud = new URL(endpoint).origin;
  const header = b64u(JSON.stringify({ typ: "JWT", alg: "ES256" }));
  const claims = b64u(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: vapid.subject }));
  const pub = unb64u(vapid.publicKey);
  const key = crypto.createPrivateKey({
    format: "jwk",
    key: { kty: "EC", crv: "P-256", d: vapid.privateKey, x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33, 65)) },
  });
  const sig = crypto.sign("sha256", Buffer.from(`${header}.${claims}`), { key, dsaEncoding: "ieee-p1363" });
  return `vapid t=${header}.${claims}.${b64u(sig)}, k=${vapid.publicKey}`;
}

// aes128gcm content encoding (RFC 8188) with the Web Push key derivation (RFC 8291).
// salt and senderPrivateKey are only passed in by the tests.
export function encrypt(text, p256dh, auth, { salt = crypto.randomBytes(16), senderPrivateKey } = {}) {
  const uaPublic = unb64u(p256dh);
  const sender = crypto.createECDH("prime256v1");
  if (senderPrivateKey) sender.setPrivateKey(unb64u(senderPrivateKey)); else sender.generateKeys();
  const asPublic = sender.getPublicKey();
  const shared = sender.computeSecret(uaPublic);
  const ikm = Buffer.from(crypto.hkdfSync("sha256", shared, unb64u(auth), Buffer.concat([Buffer.from("WebPush: info\0"), uaPublic, asPublic]), 32));
  const cek = Buffer.from(crypto.hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
  const nonce = Buffer.from(crypto.hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
  const cipher = crypto.createCipheriv("aes-128-gcm", cek, nonce);
  const body = Buffer.concat([cipher.update(Buffer.concat([Buffer.from(text), Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const head = Buffer.alloc(21);
  salt.copy(head, 0);
  head.writeUInt32BE(4096, 16);
  head[20] = asPublic.length;
  return Buffer.concat([head, asPublic, body]);
}

// Sends one message to one phone. Returns the push service's HTTP status:
// 201 is delivered, 404 or 410 means the phone has unsubscribed and the subscription can go.
export async function sendPush(sub, message, vapid, ttl = 24 * 3600) {
  const res = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      TTL: String(ttl),
      Urgency: "high",
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      Authorization: vapidHeader(sub.endpoint, vapid),
    },
    body: encrypt(JSON.stringify(message), sub.p256dh, sub.auth),
  });
  return res.status;
}
