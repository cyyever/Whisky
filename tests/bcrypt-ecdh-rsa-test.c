/*
 * Regression test for patches/proton-wine/0020-bcrypt-gnutls-ecdh-and-gmp-raw-rsa.patch:
 *   1. ECDH_P256, ECDH_P384, ECDH_P521 key exchange via BCryptSecretAgreement +
 *      BCryptDeriveKey(BCRYPT_KDF_RAW_SECRET) derives matching 32/48/66-byte
 *      shared secrets on both peers without libgcrypt.
 *   2. RSA BCRYPT_PAD_NONE raw encrypt/decrypt round-trips cleanly via GMP and
 *      rejects mismatched input lengths with STATUS_INVALID_PARAMETER.
 *
 * Compile:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o bcrypt-ecdh-rsa-test.exe \
 *       tests/bcrypt-ecdh-rsa-test.c -lbcrypt
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef STATUS_SUCCESS
#define STATUS_SUCCESS ((NTSTATUS)0x00000000)
#endif
#ifndef STATUS_INVALID_PARAMETER
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000D)
#endif
#ifndef BCRYPT_KDF_RAW_SECRET
#define BCRYPT_KDF_RAW_SECRET L"TRUNCATE"
#endif

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

static void test_ecdh(LPCWSTR alg_name, ULONG bits, ULONG expect_bytes, const char *label)
{
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_KEY_HANDLE priv_a = NULL, priv_b = NULL, pub_a = NULL, pub_b = NULL;
    BCRYPT_SECRET_HANDLE sec_a = NULL, sec_b = NULL;
    UCHAR *blob_a = NULL, *blob_b = NULL;
    UCHAR out_a[128], out_b[128];
    ULONG blob_a_len = 0, blob_b_len = 0, len_a = 0, len_b = 0;
    NTSTATUS st;

    st = BCryptOpenAlgorithmProvider(&alg, alg_name, NULL, 0);
    CHECK(st == STATUS_SUCCESS, "[%s] OpenAlgorithmProvider (st=0x%08lx)", label, (unsigned long)st);
    if (st != STATUS_SUCCESS) return;

    st = BCryptGenerateKeyPair(alg, &priv_a, bits, 0);
    if (st == STATUS_SUCCESS) st = BCryptFinalizeKeyPair(priv_a, 0);
    CHECK(st == STATUS_SUCCESS, "[%s] GenerateKeyPair A (st=0x%08lx)", label, (unsigned long)st);

    st = BCryptGenerateKeyPair(alg, &priv_b, bits, 0);
    if (st == STATUS_SUCCESS) st = BCryptFinalizeKeyPair(priv_b, 0);
    CHECK(st == STATUS_SUCCESS, "[%s] GenerateKeyPair B (st=0x%08lx)", label, (unsigned long)st);
    if (!priv_a || !priv_b) goto done;

    st = BCryptExportKey(priv_a, NULL, BCRYPT_ECCPUBLIC_BLOB, NULL, 0, &blob_a_len, 0);
    blob_a = (UCHAR *)malloc(blob_a_len);
    if (st == STATUS_SUCCESS && blob_a)
        st = BCryptExportKey(priv_a, NULL, BCRYPT_ECCPUBLIC_BLOB, blob_a, blob_a_len, &blob_a_len, 0);
    if (st == STATUS_SUCCESS)
        st = BCryptImportKeyPair(alg, NULL, BCRYPT_ECCPUBLIC_BLOB, &pub_a, blob_a, blob_a_len, 0);

    if (st == STATUS_SUCCESS)
        st = BCryptExportKey(priv_b, NULL, BCRYPT_ECCPUBLIC_BLOB, NULL, 0, &blob_b_len, 0);
    blob_b = (UCHAR *)malloc(blob_b_len);
    if (st == STATUS_SUCCESS && blob_b)
        st = BCryptExportKey(priv_b, NULL, BCRYPT_ECCPUBLIC_BLOB, blob_b, blob_b_len, &blob_b_len, 0);
    if (st == STATUS_SUCCESS)
        st = BCryptImportKeyPair(alg, NULL, BCRYPT_ECCPUBLIC_BLOB, &pub_b, blob_b, blob_b_len, 0);
    CHECK(st == STATUS_SUCCESS && pub_a && pub_b, "[%s] Export/Import public blobs (st=0x%08lx)", label, (unsigned long)st);
    if (st != STATUS_SUCCESS || !pub_a || !pub_b) goto done;

    st = BCryptSecretAgreement(priv_a, pub_b, &sec_a, 0);
    CHECK(st == STATUS_SUCCESS, "[%s] SecretAgreement A->B (st=0x%08lx)", label, (unsigned long)st);
    st = BCryptSecretAgreement(priv_b, pub_a, &sec_b, 0);
    CHECK(st == STATUS_SUCCESS, "[%s] SecretAgreement B->A (st=0x%08lx)", label, (unsigned long)st);
    if (!sec_a || !sec_b) goto done;

    memset(out_a, 0, sizeof(out_a));
    memset(out_b, 0, sizeof(out_b));
    st = BCryptDeriveKey(sec_a, BCRYPT_KDF_RAW_SECRET, NULL, out_a, sizeof(out_a), &len_a, 0);
    CHECK(st == STATUS_SUCCESS && len_a == expect_bytes,
          "[%s] DeriveKey A len=%lu (expected %lu, st=0x%08lx)",
          label, (unsigned long)len_a, (unsigned long)expect_bytes, (unsigned long)st);
    st = BCryptDeriveKey(sec_b, BCRYPT_KDF_RAW_SECRET, NULL, out_b, sizeof(out_b), &len_b, 0);
    CHECK(st == STATUS_SUCCESS && len_b == expect_bytes,
          "[%s] DeriveKey B len=%lu (expected %lu, st=0x%08lx)",
          label, (unsigned long)len_b, (unsigned long)expect_bytes, (unsigned long)st);
    CHECK(len_a == expect_bytes && len_b == expect_bytes && memcmp(out_a, out_b, expect_bytes) == 0,
          "[%s] Shared secrets match between A and B", label);

done:
    if (sec_a) BCryptDestroySecret(sec_a);
    if (sec_b) BCryptDestroySecret(sec_b);
    if (pub_a) BCryptDestroyKey(pub_a);
    if (pub_b) BCryptDestroyKey(pub_b);
    if (priv_a) BCryptDestroyKey(priv_a);
    if (priv_b) BCryptDestroyKey(priv_b);
    free(blob_a);
    free(blob_b);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
}

static void test_rsa_raw(void)
{
    BCRYPT_ALG_HANDLE alg = NULL;
    BCRYPT_KEY_HANDLE key = NULL;
    UCHAR plain[64], enc[64], dec[64], short_in[11] = "Hello";
    ULONG enc_len = 0, dec_len = 0;
    NTSTATUS st;

    st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_RSA_ALGORITHM, NULL, 0);
    CHECK(st == STATUS_SUCCESS, "[RSA-RAW] OpenAlgorithmProvider (st=0x%08lx)", (unsigned long)st);
    if (st != STATUS_SUCCESS) return;

    st = BCryptGenerateKeyPair(alg, &key, 512, 0);
    if (st == STATUS_SUCCESS) st = BCryptFinalizeKeyPair(key, 0);
    CHECK(st == STATUS_SUCCESS, "[RSA-RAW] GenerateKeyPair 512-bit (st=0x%08lx)", (unsigned long)st);
    if (st != STATUS_SUCCESS) goto done;

    memset(plain, 0, sizeof(plain));
    plain[0] = 0x00; /* ensure msg < modulus */
    memcpy(plain + 1, "Whisky-RSA-BCRYPT_PAD_NONE-test", 31);

    st = BCryptEncrypt(key, short_in, sizeof(short_in), NULL, NULL, 0, enc, sizeof(enc), &enc_len, BCRYPT_PAD_NONE);
    CHECK(st == (NTSTATUS)STATUS_INVALID_PARAMETER, "[RSA-RAW] Rejects short input (st=0x%08lx)", (unsigned long)st);

    st = BCryptEncrypt(key, plain, sizeof(plain), NULL, NULL, 0, enc, sizeof(enc), &enc_len, BCRYPT_PAD_NONE);
    CHECK(st == STATUS_SUCCESS && enc_len == sizeof(enc),
          "[RSA-RAW] Encrypt PAD_NONE len=%lu (st=0x%08lx)", (unsigned long)enc_len, (unsigned long)st);

    memset(dec, 0, sizeof(dec));
    st = BCryptDecrypt(key, enc, enc_len, NULL, NULL, 0, dec, sizeof(dec), &dec_len, BCRYPT_PAD_NONE);
    CHECK(st == STATUS_SUCCESS && dec_len == sizeof(plain) && memcmp(dec, plain, sizeof(plain)) == 0,
          "[RSA-RAW] Decrypt PAD_NONE round-trip matches (len=%lu st=0x%08lx)",
          (unsigned long)dec_len, (unsigned long)st);

done:
    if (key) BCryptDestroyKey(key);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
}

int main(void)
{
    test_ecdh(BCRYPT_ECDH_P256_ALGORITHM, 256, 32, "ECDH_P256");
    test_ecdh(BCRYPT_ECDH_P384_ALGORITHM, 384, 48, "ECDH_P384");
    test_ecdh(BCRYPT_ECDH_P521_ALGORITHM, 521, 66, "ECDH_P521");
    test_rsa_raw();

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}
