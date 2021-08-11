#!/bin/bash

###
## This is a slightly changed reproducer of <github>
## for verifying https://bugzilla.redhat.com/show_bug.cgi?id=1985304
##
## The documentation: https://docs.openshift.com/container-platform/4.8/security/certificates/replacing-default-ingress-certificate.html
###

set -e

PASSWORD=${PASSWORD:-password}
DIR="$( dirname "${BASH_SOURCE[0]}")"

function create_ca() {
    # gen cert/key pair for CA, use password to secure the key because why not
    openssl genrsa -aes256 -passout "pass:$PASSWORD" -out "${DIR}/rootCA.key" 4096
    openssl req -x509 -new -nodes -key "${DIR}/rootCA.key" \
        -sha512 -days 3655 -out "${DIR}/rootCA.crt" \
        -subj "/C=CZ/ST=Moravia/O=My Private Org Ltd./CN=Test CA" \
        -extensions v3_ca -config "${DIR}/custom.cnf" \
        -passin "pass:${PASSWORD}"
}

function create_client() {
    # generate cert/key pair for client auth, let's omit password for simplicity of use
    openssl genrsa -out "${DIR}/client.key" 4096
    openssl req -new -sha256 -key "${DIR}/client.key" \
        -subj "/C=CZ/ST=Moravia/O=My Private Org Ltd./CN=somewhere.com" \
        -out "${DIR}/client.csr"

    openssl x509 -req -in "${DIR}/client.csr" -CA "${DIR}/rootCA.crt" \
        -CAkey "${DIR}/rootCA.key" -CAcreateserial -out "${DIR}/client.crt" \
        -days 1024 -sha256 -extfile "${DIR}/custom.cnf" -extensions client_auth \
        -passin "pass:${PASSWORD}"
}

function create_server() {
    server_name=${1:-somewhere.com}
    # generate cert/key pair for server, let's omit password for simplicity of use
    openssl genrsa -out "${DIR}/server.key" 4096
    openssl req -new -sha256 -key "${DIR}/server.key" \
        -subj "/CN=${server_name}" \
        -out "${DIR}/server.csr"

    openssl x509 -req -in "${DIR}/server.csr" -CA "${DIR}/rootCA.crt" \
        -CAkey "${DIR}/rootCA.key" -CAcreateserial -out "${DIR}/server.crt" \
        -days 1024 -sha256 -extfile "${DIR}/custom.cnf" -extensions server_auth \
        -passin "pass:${PASSWORD}"
}

function config_bz_1985304() {
    DOMAIN=$(oc get ingresscontroller.operator -n openshift-ingress-operator default -o template='{{ .status.domain }}')
    DOMAIN_WILDCARD="*.$DOMAIN"
    export SAN="DNS:$DOMAIN_WILDCARD"
    create_ca
    create_server "$DOMAIN_WILDCARD"
    create_client

    oc delete configmap custom-ca -n openshift-config || true
    oc delete secret custom-certs -n openshift-ingress || true

    oc create configmap custom-ca --from-file=ca-bundle.crt=rootCA.crt -n openshift-config
    oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'
    oc create secret tls custom-certs --cert=server.crt --key=server.key -n openshift-ingress
    oc patch ingresscontroller.operator default --type=merge -p '{"spec":{"defaultCertificate": {"name": "custom-certs"}}}' -n openshift-ingress-operator
}

config_bz_1985304
