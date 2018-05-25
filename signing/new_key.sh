#!/usr/bin/env bash

set -ex
KEY="$1"
openssl genrsa -rand /dev/random -out "${KEY}.key.pem" 2048
openssl rsa -in "${KEY}.key.pem" -pubout -out "${KEY}.pub.pem"
