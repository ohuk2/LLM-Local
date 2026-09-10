# Air-Gapped LLM Deployment (AWS)

Self-hosted Ollama + Open WebUI stack running in a private AWS VPC with **no internet gateway and no NAT gateway**. All AWS API traffic goes through VPC endpoints; everything else (container images, models) is staged manually and transferred in.

## Architecture

- Private VPC, single private subnet, no route to the internet
- GPU EC2 instance running Docker Compose: **Caddy** (TLS reverse proxy) → **Open WebUI** (chat UI) → **Ollama** (inference)
- VPC endpoints: S3 (gateway), ECR, SSM, SSM Messages, EC2 Messages, CloudWatch Logs (interface)
- Access via AWS Systems Manager Session Manager — no SSH, no public IP
- Model bundle (Compose files, container images, model weights) staged in an S3 bucket, pulled down by the instance on first boot

## Repo structure

```
├── docker-compose.yml
├── Caddyfile
├── .env.example
├── .gitignore
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── user_data.sh.tpl
```

## Prerequisites (local machine)

| Tool | Install |
|---|---|
| Terraform | `brew install hashicorp/tap/terraform` |
| AWS CLI v2 | `brew install awscli` (check `aws --version` — keep this current) |
| Session Manager plugin | `brew install --cask session-manager-plugin` |
| Docker Desktop | docker.com — needed to stage container images |
| Git | `brew install git` |

Run `aws configure` with an IAM user/role that has permissions for VPC, EC2, IAM role creation, and VPC endpoints.

## 1. Stage the S3 bucket

The bucket referenced by `model_bundle_bucket` must exist **before** you run Terraform — Terraform attaches a policy to it but doesn't create it.

```bash
aws s3 mb s3://your-bucket-name --region eu-west-2
```

Upload the compose stack:

```bash
aws s3 cp docker-compose.yml s3://your-bucket-name/bundle/docker-compose.yml
aws s3 cp Caddyfile s3://your-bucket-name/bundle/Caddyfile
aws s3 cp .env s3://your-bucket-name/bundle/.env      # copy from .env.example first, fill in real values
```

## 2. Stage container images (registry pulls will not work — no internet route)

On a machine **with** internet access:

```bash
docker pull ollama/ollama:latest
docker pull ghcr.io/open-webui/open-webui:main
docker pull caddy:2-alpine

mkdir -p images
docker save ollama/ollama:latest -o images/ollama.tar
docker save ghcr.io/open-webui/open-webui:main -o images/open-webui.tar
docker save caddy:2-alpine -o images/caddy.tar

aws s3 cp images/ s3://your-bucket-name/bundle/images/ --recursive
```

## 3. Configure Terraform

```bash
cd terraform
cat > terraform.tfvars <<EOF
model_bundle_bucket   = "your-bucket-name"
allowed_ingress_cidrs = ["203.0.113.0/24"]   # your real VPN/office CIDR, never 0.0.0.0/0
region                = "eu-west-2"
instance_type         = "g5.xlarge"           # or t3.medium for plumbing-only tests, g4dn.xlarge for cheaper GPU tests
EOF
```

`terraform.tfvars` is already covered by `.gitignore` — it stays local, never committed.

## 4. Check your GPU quota (if using a GPU instance type)

New AWS accounts often default to a 0-vCPU quota for the G-instance family. Check **Service Quotas → EC2 → "Running On-Demand G and VT instances"** in your target region before applying, or the `apply` will fail at instance creation.

## 5. Deploy

```bash
terraform init
terraform plan
terraform apply
```

Note the `instance_id` and `private_ip` outputs.

## 6. Connect

```bash
aws ssm start-session --target <instance_id>
```

## 7. Complete the deployment manually

`user_data.sh.tpl` runs the S3 pull automatically on first boot, but in practice you may need to re-run parts of it by hand (see Troubleshooting below). On the instance:

```bash
cd /opt/airgapped-llm
sudo aws s3 cp s3://your-bucket-name/bundle/ . --recursive
sudo aws s3 cp s3://your-bucket-name/bundle/images/ ./images/ --recursive
for t in images/*.tar; do sudo docker load -i "$t"; done
sudo docker compose up -d
sudo docker compose ps
```

All three containers (`caddy`, `ollama`, `open-webui`) should show `Up`, and `open-webui` should settle to `(healthy)` within a minute or two.

## 8. Load a model (registry pulls do not work here either)

On a machine with internet access:

```bash
ollama pull deepseek-r1:8b        # or llama3.1:8b, etc.
tar czf ollama-models.tar.gz -C ~/.ollama .
aws s3 cp ollama-models.tar.gz s3://your-bucket-name/bundle/models/
```

On the instance:

```bash
cd /opt/airgapped-llm
sudo aws s3 cp s3://your-bucket-name/bundle/models/ollama-models.tar.gz .
sudo docker cp ollama-models.tar.gz ollama:/tmp/
sudo docker exec ollama tar xzf /tmp/ollama-models.tar.gz -C /root/.ollama
sudo docker exec ollama ollama list      # confirm it shows up
```

For a custom GGUF (e.g. a community fine-tune from Hugging Face) instead of an Ollama-library model, stage the `.gguf` file plus a `Modelfile` (`FROM ./model.gguf`) the same way, then run `docker exec ollama ollama create <name> -f /tmp/Modelfile` on the instance.

## 9. Test

```bash
# on the instance
curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost/    # expect 200
```

```bash
# on your laptop, new terminal
aws ssm start-session --target <instance_id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'
```

Open `https://localhost:8443` — accept the self-signed cert warning — and you should reach the Open WebUI signup screen.

## Tear down

```bash
terraform destroy
```

Removes the VPC, endpoints, IAM role, and instance. The S3 bucket and its contents are not managed by Terraform and persist separately.

---

## Troubleshooting — issues hit during setup and their fixes

| Symptom | Cause | Fix |
|---|---|---|
| `aws s3 cp` (and anything else through the S3 **gateway** endpoint) hangs indefinitely, `timeout` returns exit code 124 | The security group's egress rule only allowed traffic to the VPC CIDR. S3 gateway endpoint traffic is routed internally but still targets S3's *public* IP ranges from the security group's perspective, so it was silently dropped | Add a second egress rule scoped to the AWS-managed S3 prefix list (`data "aws_prefix_list" "s3"`, `com.amazonaws.<region>.s3`) allowing port 443 |
| `docker compose up -d` fails: `failed to resolve reference "docker.io/..."`, `dial tcp ... i/o timeout` | No internet route — Compose was trying to pull images from Docker Hub / GHCR | Stage images as `docker save` tarballs via S3 (see step 2) and `docker load` them before `docker compose up -d` |
| `open-webui` container stays `unhealthy` for several minutes, `curl` to Caddy returns `502` | Open WebUI hangs on startup trying to download its RAG embedding model from Hugging Face and/or phone home for telemetry — no internet route to reach either | Add `HF_HUB_OFFLINE=1`, `ANONYMIZED_TELEMETRY=false`, `DO_NOT_TRACK=1`, `SCARF_NO_ANALYTICS=true` to the `open-webui` service's environment in `docker-compose.yml`. Note: this disables RAG/document-upload until the embedding model is staged separately |
| Chat request errors: `<model> does not support tools` | Open WebUI's per-model **Builtin Tools** capability (Time & Calculation, Ask User, Memory, Notes, Knowledge Base, etc.) is checked on by default and attaches a `tools` payload to every request. Older/uncensored models (e.g. `llama2-uncensored`) have no tool-calling chat template and reject it | In Admin Panel → Settings → Models → select the model, uncheck **Builtin Tools** and the individual tool entries under it, plus Web Search / Terminal / Code Interpreter / Image Generation. Also check the wrench/tools icon in the chat input bar itself, which can override the model default per-conversation |
| |
| `aws ssm start-session`: `SessionManagerPlugin is not found` | Plugin not installed — it's separate from the AWS CLI itself | `brew install --cask session-manager-plugin` |
| Very long `terraform apply` time on `aws_instance` (20+ min for a small instance) | Observed but not conclusively diagnosed — can occur with interface endpoint DNS propagation or AZ capacity | Not an error if it eventually completes; worth watching if consistently slow |

## Notes on ongoing operation

- **Updating the stack**: edit `docker-compose.yml`/`Caddyfile` locally, re-upload to `s3://your-bucket-name/bundle/`, then on the instance `sudo aws s3 cp s3://your-bucket-name/bundle/ . --recursive && sudo docker compose up -d`.
- **Multiple customer sites**: keep this repo as a single template; vary `terraform.tfvars` per site (different `allowed_ingress_cidrs`, `model_bundle_bucket`, `region`). Don't fork per customer.
- **Terraform state**: currently local. For a real multi-site rollout, move to a remote S3 backend (a separate bucket from the model bundle, since that one's locked to the VPC endpoint) with DynamoDB locking.
- **Secrets**: `.env`, `terraform.tfvars`, and `*.tfstate` are all gitignored. Never commit real values — only the `.env.example` template.