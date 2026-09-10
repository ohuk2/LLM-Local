#!/bin/bash
set -euxo pipefail

# Deep Learning AMI already has the NVIDIA driver + container toolkit.
# Docker Compose plugin only needs adding on some AMI variants:
if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker-compose-plugin
fi

mkdir -p /opt/airgapped-llm
cd /opt/airgapped-llm

# Pull the staged bundle (docker-compose.yml, Caddyfile, .env, and any
# pre-exported model image tarballs) from the S3 bucket reachable only
# via the VPC gateway endpoint.
aws s3 cp "s3://${model_bundle_bucket}/bundle/" . --recursive

# If model weights were shipped as `docker save` tarballs instead of pulled
# from a registry, load them now:
for tarball in ./images/*.tar; do
  [ -f "$tarball" ] && docker load -i "$tarball"
done

docker compose up -d

# Once the stack is up, pull/import the actual model into the ollama
# volume — either via `docker exec ollama ollama pull <model>` if a
# private registry mirror is reachable through the ECR/S3 endpoints,
# or by importing a pre-staged GGUF with a Modelfile shipped in the bundle:
# docker exec ollama ollama create my-model -f /root/.ollama/Modelfile
