# ca/ - the trust anchor

Nothing in this directory is committed. The files here are local to one box.

| File | What it is | Made by |
|---|---|---|
| `partyos-ca.crt` | the root CA certificate, the anchor every client pins | `scripts/deploy/gen-ca.sh` or `install-certs.sh` |
| `partyos-ca.key` | the root CA private key. SECRET. | `scripts/deploy/gen-ca.sh` |
| `partyos-ca.srl` | openssl serial bookkeeping | openssl |
| `EXTERNAL-CA` | marker: an external (venue) CA is installed | `install-certs.sh` |
| `*.lab-backup` | the displaced self-minted CA material, for `install-certs.sh --restore-lab` | `install-certs.sh` |

## Why the certificate is not committed

The certificate is not tracked, so a clone never holds a CA without its key.
`gen-ca.sh` refuses to run when a certificate is present and its key is not.

## Getting a CA on a new box

Run the wizard, which mints one:

```
scripts/deploy/setup.sh
```

To use a certificate signed by someone else, such as a venue CA, install it with
its leaf. Do not copy the certificate into this directory by hand.

```
scripts/deploy/install-certs.sh --ca venue-ca.crt --cert leaf.crt --key leaf.key
```

## The recorded fingerprint

Both paths record the CA fingerprint as `CA_FINGERPRINT` in `deploy.conf`.
`scripts/deploy/check-ipxe-efi.sh` compares the certificate on disk against that
record. A certificate that appears here by any other route fails the check.

Read the current fingerprint with:

```
openssl x509 -in ca/partyos-ca.crt -noout -fingerprint -sha256
```
