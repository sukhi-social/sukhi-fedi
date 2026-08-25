// パスキー(WebAuthn)のブラウザ側。サーバ(/login/passkey/* と
// /settings/passkeys/*)とは base64url の文字列でやりとりして、
// ArrayBuffer との行き来は、ぜんぶこのファイルの中だけで済ませる。
//
// sukhi-fedi 本体の web/src/lib/webauthn.ts と同じ内容。同じサーバの
// 同じ口を叩くので、形も同じにしてある。

export function passkeySupported(): boolean {
  return typeof window !== 'undefined' && !!window.PublicKeyCredential;
}

function b64uToBuf(s: string): ArrayBuffer {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function bufToB64u(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// サーバが返す publicKey オプション(チャレンジ等は base64url 文字列)。
// 形は SukhiFedi.Auth.Passkeys が作るものに揃えてある。
type ServerCreationOptions = {
  challenge: string;
  rp: { id: string; name: string };
  user: { id: string; name: string; displayName: string };
  pubKeyCredParams: { type: 'public-key'; alg: number }[];
  authenticatorSelection: AuthenticatorSelectionCriteria;
  excludeCredentials?: { type: 'public-key'; id: string }[];
  timeout: number;
  attestation: AttestationConveyancePreference;
};

type ServerRequestOptions = {
  challenge: string;
  rpId: string;
  userVerification: UserVerificationRequirement;
  timeout: number;
};

export type RegistrationPayload = {
  attestation_object: string;
  client_data_json: string;
};

export type AssertionPayload = {
  credential_id: string;
  authenticator_data: string;
  signature: string;
  client_data_json: string;
  user_handle: string | null;
};

export async function createPasskey(options: ServerCreationOptions): Promise<RegistrationPayload> {
  const publicKey: PublicKeyCredentialCreationOptions = {
    ...options,
    challenge: b64uToBuf(options.challenge),
    user: { ...options.user, id: b64uToBuf(options.user.id) },
    excludeCredentials: (options.excludeCredentials ?? []).map((c) => ({
      type: 'public-key' as const,
      id: b64uToBuf(c.id)
    }))
  };

  const cred = (await navigator.credentials.create({ publicKey })) as PublicKeyCredential | null;
  if (!cred) throw new Error('passkey_cancelled');
  const resp = cred.response as AuthenticatorAttestationResponse;

  return {
    attestation_object: bufToB64u(resp.attestationObject),
    client_data_json: bufToB64u(resp.clientDataJSON)
  };
}

export async function getPasskeyAssertion(options: ServerRequestOptions): Promise<AssertionPayload> {
  const publicKey: PublicKeyCredentialRequestOptions = {
    ...options,
    challenge: b64uToBuf(options.challenge)
  };

  const cred = (await navigator.credentials.get({ publicKey })) as PublicKeyCredential | null;
  if (!cred) throw new Error('passkey_cancelled');
  const resp = cred.response as AuthenticatorAssertionResponse;

  return {
    credential_id: cred.id,
    authenticator_data: bufToB64u(resp.authenticatorData),
    signature: bufToB64u(resp.signature),
    client_data_json: bufToB64u(resp.clientDataJSON),
    user_handle: resp.userHandle ? bufToB64u(resp.userHandle) : null
  };
}
