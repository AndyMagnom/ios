#!/bin/sh
# Input is a public PEM certificate. No private key needed or printed.
set -eu
cert_path=${1:?Usage: spki-pin.sh /path/to/public-certificate.pem}
pin_work_dir=$(mktemp -d)
trap 'rm -rf "$pin_work_dir"' EXIT HUP INT TERM
openssl x509 -in "$cert_path" -pubkey -noout > "$pin_work_dir/public.pem"
openssl pkey -pubin -in "$pin_work_dir/public.pem" -outform DER -out "$pin_work_dir/public.der"
openssl dgst -sha256 -binary "$pin_work_dir/public.der" | openssl base64 -A
printf '\n'
