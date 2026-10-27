# Zero-Knowledge End-to-End Encryption (E2EE) for Cloud Sync & Media Storage

> **Issue**: #245  
> **Branch**: `feat/245-e2ee-sync-storage`  
> **Status**: Architecture & Implementation Plan  

---

## 1. Executive Summary & Zero-Knowledge Guarantee

Augustyniak Capture guarantees offline-first voice recording with durable storage. When users sign in with Supabase/Google Auth, cloud sync coordinates metadata and media across devices. 

Currently, Row-Level Security (RLS) guarantees user isolation at the tenant level, but content (`transcript`, `title`, `summary`, `tags`, audio media files) is stored unencrypted in PostgreSQL and Supabase Storage.

**The Zero-Knowledge E2EE Architecture introduces:**
1. **Zero-Knowledge Principle**: The server (PostgreSQL and Supabase Storage) and database administrators have **zero access** to audio recordings, transcripts, titles, summaries, tags, clipboard text, or project paths. The cloud holds only authenticated ciphertext (`nonce` + `ciphertext` + `mac`).
2. **Permanent Loss Consequence**: Encryption keys are derived strictly from a user-provided passphrase on the client. Neither the server nor any recovery endpoint stores the key. **If the user loses the passphrase, data is permanently and irrevocably lost.**

---

## 2. Cryptographic Architecture

### 2.1 Primitives (Built on `package:cryptography`)
* **Key Derivation Function (KDF)**:
  * Algorithm: `Pbkdf2` with `Hmac.sha256()`, 100,000 iterations, 256-bit output key.
  * Salt: 16 cryptographically random bytes generated locally per user account.
  * Public KDF metadata: Stored in `public.user_e2ee_settings` (`kdf_salt`, `kdf_algorithm`, `key_check_hash`).
* **Symmetric Authenticated Encryption**:
  * Algorithm: `AesGcm.with256bits()`.
  * Nonce: 12 random bytes per encryption.
  * MAC: 16-byte authentication tag.
  * Envelope format: `enc:v1:` + base64(12-byte nonce || ciphertext || 16-byte MAC) — matches existing [`AesGcmTokenCipher`](file:///home/laugustyniak/github/tools/augustyniak-capture/lib/features/settings/data/aes_gcm_token_cipher.dart).

```
+------------------------------------------------------------------------+
|                          Master Encryption Key                         |
|     Passphrase (User secret) + Salt (Public) --[PBKDF2-HMAC-SHA256]--> |
+------------------------------------------------------------------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v                                           v
    [Metadata & Text E2EE]                         [Media Audio E2EE]
+-----------------------------+               +--------------------------+
| recordings:                 |               | Audio / Video / Image    |
|   transcript, title,        |               | Streaming AES-256-GCM    |
|   summary, tags, payload    |               |                          |
|                             |               | Ciphertext uploaded to   |
| -> Pack into JSON           |               | Supabase Storage bucket  |
| -> Encrypt AES-256-GCM      |               | 'captures'               |
| -> 'encrypted_payload'      |               |                          |
| Plaintext columns set NULL  |               | On download: decrypt     |
+-----------------------------+               | Verify SHA256 == hash    |
               |                              +--------------------------+
               v                                           |
     PostgreSQL (Supabase)                        Supabase Storage
   (Only Ciphertext Stored)                   (Only Ciphertext Stored)
```

---

## 3. Database Schema & Migration

Migration file: [`supabase/migrations/20261006200000_e2ee_encrypted_payload.sql`](file:///home/laugustyniak/github/tools/augustyniak-capture/.worktrees/feat-245-e2ee-sync-storage/supabase/migrations/20261006200000_e2ee_encrypted_payload.sql)

1. **`encrypted_payload text` added to:**
   * `public.recordings`
   * `public.segments`
   * `public.clipboard_items`
   * `public.projects`
2. **`public.user_e2ee_settings` table:**
   * `owner_id uuid primary key references auth.users(id)`
   * `kdf_salt text not null`
   * `kdf_algorithm text not null`
   * `key_check_hash text not null` (used by client to verify password without server knowing password)
   * Protected with `FORCE ROW LEVEL SECURITY`, `owner_id = (select auth.uid())` and `reject_owner_change()` trigger.

---

## 4. TDD Implementation Slices

### Slice 1: Cryptographic Engine & Key Derivation
* **Files**:
  * `lib/features/sync/domain/e2ee_key_derivation.dart`
  * `lib/features/sync/domain/e2ee_cipher.dart`
  * `test/sync/e2ee_cipher_test.dart`
* **Tests**:
  1. PBKDF2 derives identical 256-bit key from identical passphrase and salt.
  2. PBKDF2 produces distinct keys for different salts or passphrases.
  3. Key check hash validates valid passphrase and rejects invalid passphrase.
  4. Encrypt/decrypt round-trips arbitrary UTF-8 strings.
  5. Decrypt throws on altered ciphertext or incorrect key.

### Slice 2: Metadata Encryption in `SyncRowCodec`
* **Files**:
  * `lib/features/sync/domain/sync_row_codec.dart`
  * `test/sync/sync_row_codec_e2ee_test.dart`
* **Tests**:
  1. When E2EE cipher is present, `SyncRowCodec.recording(r)` sets `encrypted_payload` and strips plaintext (`transcript = null`, `title = null`, `summary = null`, `tags = []`, `payload = null`).
  2. `SyncRowCodec.recordingFromRow(row)` decrypts `encrypted_payload` and restores all original plaintext fields.
  3. Segments, clipboard items, and projects similarly encrypt sensitive attributes into `encrypted_payload`.
  4. Graceful handling: If row was saved pre-E2EE (plaintext columns present), decodes normally.

### Slice 3: Media File Encryption in `SupabaseMediaStore`
* **Files**:
  * `lib/features/sync/data/encrypted_media_store.dart`
  * `test/sync/encrypted_media_store_test.dart`
* **Tests**:
  1. `EncryptedMediaStore` wraps `MediaObjectStore`.
  2. Upload encrypts local file bytes before passing to inner store; remote payload is verifiable ciphertext.
  3. Download fetches ciphertext, decrypts with MEK, and returns clear bytes.
  4. Decrypted bytes match original `contentHash` SHA-256 in `MediaSyncService`.

### Slice 4: UI & Onboarding Flow for E2EE Passphrase
* **Files**:
  * `lib/features/auth/presentation/e2ee_setup_dialog.dart`
  * `lib/features/auth/presentation/account_section.dart`
* **Requirements**:
  1. User enters passphrase when enabling E2EE or signing in on a new device.
  2. Unmistakable warning modal: "Augustyniak Capture cannot recover your passphrase. If you forget it, all encrypted notes and recordings will be lost permanently."
  3. Secure storage of active session key in OS keyring (`flutter_secure_storage`).

---

## 5. Verification Checklist

- [x] Dedicated worktree `.worktrees/feat-245-e2ee-sync-storage` created and tracking `origin/main`.
- [x] Dependencies verified (`flutter pub get` succeeded, 17 existing sync tests pass).
- [x] Database migration `20261006200000_e2ee_encrypted_payload.sql` written.
- [x] pgTAP SQL verification test `supabase/tests/e2ee_encrypted_payload_test.sql` written.
- [x] Architecture & TDD plan document registered in `docs/plans/2026-10-06-e2ee-sync-and-storage.md`.
