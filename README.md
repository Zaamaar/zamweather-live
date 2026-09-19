# ZamWeather

A weather application built on a production-style three-tier AWS architecture, provisioned entirely with Terraform. Every search is saved to a MySQL database. The whole backend — VPC, subnets, ALB, EC2, RDS — is declared in code and reproducible with a single `terraform apply`.

This README documents not just what was built, but every architectural compromise made along the way and why. Because the gap between a designed architecture and a deployed one is where real engineering happens.

**Live app:** [zamweather.netlify.app](https://zamweather.netlify.app)

---

## Architecture

### Designed Architecture (Production Target)

```
                       [ User ]
                          │
                     [ Route 53 ]
                          │
              [ CloudFront + WAF + ACM ]
              (edge caching, HTTPS, firewall)
                          │
              [ ALB 1 — internet-facing ]
              (public subnets, us-east-1a/1b)
                          │
             [ Presentation ASG — EC2 ]
             (private subnets, multi-AZ)
                          │
              [ ALB 2 — internal ]
                          │
             [ Application ASG — EC2 ]
             (private subnets, multi-AZ)
                          │
               [ RDS MySQL — Multi-AZ ]
         (primary us-east-1a | standby us-east-1b)

Supporting:
┌────────────────────────────────────────────┐
│  NAT Gateways  (one per AZ, outbound only) │
│  WAF           (OWASP rules + rate limits) │
│  ACM           (TLS certificate)           │
│  CloudWatch    (logs and metrics)          │
└────────────────────────────────────────────┘
```

### What Was Actually Deployed (with documented trade-offs)

```
               [ User / Browser ]
                      │
              [ Netlify CDN — HTTPS ]
              (global edge, GitHub auto-deploy)
                      │
              _redirects proxy: /api/* →
                      │
         [ ALB — internet-facing, HTTP ]
         (us-east-1a and us-east-1b)
                      │
         [ EC2 t2.micro — Flask API ]
         (PUBLIC subnet — see trade-off #2)
         (ASG min=1 max=1 — see trade-off #3)
              │               │
 [ OpenWeatherMap API ]  [ RDS MySQL db.t3.micro ]
 (live weather data)     (private subnet, single-AZ)
                         (see trade-off #4)

Network layout:
┌────────────────────────────────────────────────┐
│  VPC (custom CIDR)                              │
│  Public subnets   → ALB                        │
│  Private subnets  → EC2 Flask (compromised*)   │
│  Data subnets     → RDS MySQL                  │
│  Security groups  → ALB → EC2 → RDS only       │
│  No NAT Gateway   → see trade-off #2           │
└────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python + Flask |
| Database | AWS RDS MySQL (db.t3.micro) |
| Infrastructure-as-Code | Terraform (modular) |
| Load Balancing | AWS ALB |
| Frontend Hosting | Netlify (CDN + HTTPS + GitHub deploy) |
| Proxy | Netlify `_redirects` (HTTPS → HTTP bridge) |
| Weather Data | OpenWeatherMap API |
| Monitoring | AWS CloudWatch |

---

## Terraform Structure

```
zamweather/
├── main.tf                # Root module — calls sub-modules
├── variables.tf           # Input variables
├── outputs.tf             # CloudFront domain, ALB DNS
├── terraform.tfvars       # Environment-specific values
└── modules/
    ├── vpc/               # VPC, subnets, route tables
    ├── security_groups/   # Per-tier ingress/egress rules
    ├── rds/               # MySQL instance, subnet group
    ├── alb/               # ALB, target groups, listeners
    └── ec2/               # Instances, user data, ASG
```

26 AWS resources provisioned from code. `terraform apply` builds the entire backend. `terraform destroy` removes everything cleanly.

---

## Deployment

```bash
git clone https://github.com/Zaamaar/zamweather.git
cd zamweather
terraform init
terraform plan
terraform apply
```

Frontend deploys automatically via Netlify on every GitHub push.

---

## The Trade-offs — Documented Honestly

### Trade-off #1 — CloudFront replaced by Netlify

**What was designed:** CloudFront + WAF + ACM in front of everything.

**What happened:** New AWS accounts require manual verification before CloudFront is enabled. The verification request was rejected. CloudFront was off the table.

**What replaced it:** Netlify for the frontend — free global CDN, automatic HTTPS, GitHub-triggered deploys, no AWS account restrictions.

**Why this matters:** Three users in three countries (Sweden, Canada, Nigeria) simultaneously lost access to the app during a brief S3 static hosting DNS issue. CloudFront would have served all three from edge locations near them — none would have noticed the origin issue. The constraint that forced the removal then demonstrated, in real time, exactly why CloudFront was in the design.

**Production upgrade:** Enable CloudFront once account verification passes. Attach WAF with OWASP managed rule groups and rate limiting. Add ACM certificate for HTTPS on the ALB. All of this is already in the Terraform modules — it was removed from apply, not from code.

---

### Trade-off #2 — NAT Gateways removed, EC2 moved to public subnets

**What was designed:** EC2 in private subnets, NAT Gateways in each AZ for outbound internet access (OpenWeatherMap calls, pip installs).

**What happened:** Two NAT Gateways cost ~$65/month minimum regardless of traffic. Zero revenue project.

**What replaced it:** EC2 in public subnets. Security groups only allow inbound from the ALB security group — direct internet access to instances is not possible even with public IPs, as long as security groups are correctly configured.

**Production upgrade:** Move EC2 back to private subnets. Add NAT Gateways. Update route tables. Pure cost decision, not a technical limitation.

---

### Trade-off #3 — ASG max_size = 1

**What was designed:** ASG with min=1, max=2 across two AZs for zero-downtime replacements.

**What happened:** New AWS accounts have a default limit of 1 vCPU for On-Demand Standard instances. A t2.micro uses 1 vCPU. Launching a replacement instance during a rolling update requires 2 vCPUs simultaneously. Quota increase request was rejected.

**Fix applied:** `max_size = 1` with `min_healthy_percentage = 0` on instance refresh — terminate the old instance before launching the replacement, preventing the 2-vCPU overlap. `health_check_grace_period = 300` to allow the user data script to complete.

**Production upgrade:** Request vCPU quota increase. Set `max_size = 2`, `min_healthy_percentage = 50`. Restore zero-downtime replacements.

---

### Trade-off #4 — Single-AZ RDS, no backups

**What was designed:** Multi-AZ RDS with automated backups and a 7-day retention window.

**What happened:** Multi-AZ RDS costs approximately 2× a single-AZ instance. For a learning project with no production data, the standby adds cost with no tangible benefit.

**Fix applied:** `multi_az = false`, `backup_retention_period = 0`, `skip_final_snapshot = true` for clean teardown.

**Production upgrade:** Set `multi_az = true`, `backup_retention_period = 7`. Near-zero RPO failover restored.

---

## Bugs Encountered in Production

### 1. urllib3 vs OpenSSL incompatibility
**Symptom:** Flask crashed on every boot with `ImportError: urllib3 v2.0 only supports OpenSSL 1.1.1+`

**Root cause:** Amazon Linux 2 ships with Python 3.7 and OpenSSL 1.0.2k. urllib3 v2.0+ requires OpenSSL 1.1.1+.

**Fix:** Pin `urllib3==1.26.15` in the user data pip install command.

**Diagnosed via:** `journalctl -u zamweather` over SSH. Took an hour to find. Flask was silently failing before writing any logs to disk.

---

### 2. systemd not reading environment variables
**Symptom:** Flask started with `None` as the database host and crashed immediately on the first DB call.

**Root cause:** The user data script wrote credentials to `/etc/environment`. systemd services do not reliably read `/etc/environment`.

**Fix:** Write credentials to a dedicated `/etc/zamweather.env` file. Reference it with `EnvironmentFile=/etc/zamweather.env` in the systemd unit definition.

---

### 3. Terraform templatefile() vs JavaScript template literals
**Symptom:** Terraform failed with "variable not defined" when processing `index.html`.

**Root cause:** Both Terraform's `templatefile()` and JavaScript template literals use `${}` syntax. Terraform tried to process `${city}` in the JavaScript as a Terraform variable.

**Fix:** Replaced `templatefile()` with Terraform's `replace()` function using a custom placeholder `__ALB_URL__`. Plain string substitution with no special character interpretation.

---

### 4. IAM user policy limit
**Symptom:** `LimitExceeded: Cannot exceed quota for PoliciesPerUser: 10`

**Root cause:** The existing IAM user had 10 policies attached — the AWS maximum. Adding `AdministratorAccess` failed.

**Fix:** Created a dedicated `zamweather-terraform` IAM user with `AdministratorAccess`. One policy, scoped credentials.

---

## The Mixed Content Problem and the Netlify Proxy

Netlify serves over HTTPS. The ALB serves HTTP. Browsers block HTTPS pages from making HTTP requests (Mixed Content policy).

**Solution:** A `_redirects` file in the frontend:

```
/api/*  http://zamweather-alb-xxx.us-east-1.elb.amazonaws.com/:splat  200
```

The browser calls `/api/weather` over HTTPS to Netlify. Netlify proxies it to the ALB over HTTP on the server side. Browsers don't enforce Mixed Content on server-to-server calls. The user sees only HTTPS.

This is a reverse proxy pattern — Netlify sits between the browser and the backend, translating HTTPS to HTTP transparently.

---

## Infrastructure Decisions

**Terraform modules over a monolithic main.tf:** Each infrastructure concern (networking, security, compute, CDN) is a separate module. Reusable, independently modifiable, and the separation enforces clear thinking about what belongs where.

**Everything in code, nothing clicked in the console:** Every resource is version-controlled, reviewable, and destroyable. `terraform destroy` removes 26 AWS resources cleanly. Nothing was created by hand.

**Document every trade-off with an upgrade path:** Every compromise above has a documented production path. The upgrade is not an admission of failure — it's proof of understanding what the right solution looks like and why it wasn't applied here.

**The designed architecture was correct:** Every component in the original design has a legitimate reason to exist. The S3 incident proved CloudFront's worth in real time. The mixed content error proved why HTTPS matters even for a simple app. The vCPU limits proved why quota planning matters before deployment. The design held up. The implementation adapted to reality.
