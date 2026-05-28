# 04 — Tooling Setup

> **Goal of this doc:** install everything you need on your Linux machine — the
> AWS CLI, Terraform, Git — and connect them to your AWS account **safely**, then
> prove the connection works.

You're on Linux (your environment reports a recent Ubuntu kernel). Commands below
assume **Ubuntu/Debian** (`apt`). If you're on a different distro, tell me and
I'll adapt them.

⏱️ Time: ~30 minutes.

---

## 1. What we're installing and why

| Tool | What it is | Why we need it |
|------|------------|----------------|
| **AWS CLI v2** | Command-line tool to talk to AWS | Verify credentials, inspect resources, occasional manual ops |
| **Terraform** | Infrastructure-as-Code engine | Defines and creates all our AWS resources from code |
| **Git** | Version control | Track our code; later, CI/CD with GitHub |
| **A code editor** | (You have VS Code) | Edit `.tf` and app files comfortably |

> 🧠 The AWS CLI and Terraform are *separate* tools that both authenticate to AWS
> the same way (using credentials we configure once). Terraform actually *uses*
> the same credentials the CLI uses. Set them up once, both work.

---

## 2. Install the AWS CLI v2

Run these one block at a time and read what each does.

```bash
# 1) Make sure unzip and curl exist (needed for the installer)
sudo apt-get update
sudo apt-get install -y unzip curl

# 2) Download the official AWS CLI v2 installer for 64-bit Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"

# 3) Unzip it into a folder called ./aws
unzip awscliv2.zip

# 4) Run the installer (sudo because it installs to /usr/local)
sudo ./aws/install

# 5) Verify
aws --version
```

You want output like `aws-cli/2.x.x ...`. If you see version **1.x**, you have
the old CLI from apt — uninstall it (`sudo apt remove awscli`) and reinstall v2
with the steps above.

```bash
# 6) Clean up the installer files
rm -rf awscliv2.zip aws/
```

> 🧠 **Why CLI v2, not the apt `awscli` package?** The apt package is often v1
> and outdated. AWS recommends the v2 bundled installer; it includes its own
> Python and stays current.

---

## 3. Install Terraform

We'll use HashiCorp's official apt repository so you get updates via `apt upgrade`.

```bash
# 1) Dependencies for adding a secure apt repo
sudo apt-get update
sudo apt-get install -y gnupg software-properties-common

# 2) Add HashiCorp's GPG signing key (verifies the packages are authentic)
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# 3) Add the HashiCorp apt repository for your Ubuntu codename
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# 4) Install Terraform
sudo apt-get update
sudo apt-get install -y terraform

# 5) Verify
terraform -version
```

You want `Terraform v1.x.x` (anything 1.5+ is fine for this project).

> 🧠 **Why a signed apt repo?** The GPG key lets apt verify HashiCorp actually
> published the package (not a tampered copy). This is the same trust model your
> OS uses for all its packages.

> 💡 **Optional but recommended later:** `tfenv` lets you switch Terraform
> versions per-project. Skip it for now — one global version is fine.

---

## 4. Install Git (if needed) and enable tab-completion

```bash
# Git (probably already installed)
sudo apt-get install -y git
git --version

# Optional: AWS CLI command completion in bash
echo 'complete -C "$(which aws_completer)" aws' >> ~/.bashrc
source ~/.bashrc
```

---

## 5. Create programmatic access keys for `chalaka-admin`

Terraform needs **access keys** (an Access Key ID + Secret Access Key) to act as
your `chalaka-admin` IAM user. We create them now.

> 💡 The "best practice" alternative is **IAM Identity Center (SSO)** with
> short-lived credentials. For a solo learner, long-lived access keys for one
> admin user are acceptable *if* you protect them (we will). We'll mention SSO as
> a "level up" later.

1. Log in to the Console as **`chalaka-admin`** (not root).
2. **IAM → Users → `chalaka-admin` → Security credentials**.
3. Scroll to **Access keys → Create access key**.
4. Use case: choose **Command Line Interface (CLI)**. Acknowledge the warning →
   **Next** → **Create access key**.
5. You'll see an **Access key ID** (like `AKIA...`) and a **Secret access key**
   (a long string). 🔒 **The secret is shown only once.** Copy both somewhere
   safe for the next step (a password manager — *not* a plain text file you'll
   forget about, and *never* a git repo).

> 💰🔒 **If a key ever leaks:** go straight to IAM → that user → Security
> credentials → **Deactivate/Delete** the key, then create a new one. Leaked AWS
> keys are scraped from public repos within *minutes* and used to mine crypto on
> your dime. This is why we never commit them.

---

## 6. Configure the credentials with a named profile

Instead of the default profile, we'll use a **named profile** called
`cloudcare`. Named profiles keep this project's creds separate and make the
Region explicit.

```bash
aws configure --profile cloudcare
```

It will prompt for four things — enter:

```
AWS Access Key ID [None]:      <paste the AKIA... key>
AWS Secret Access Key [None]:  <paste the long secret>
Default region name [None]:    ap-south-1
Default output format [None]:  json
```

This writes two files in your home directory:

- `~/.aws/credentials` — holds the keys, under a `[cloudcare]` section.
- `~/.aws/config` — holds the region/output, under `[profile cloudcare]`.

> 🧠 **Why a named profile, not the default?** If you ever add a second account
> or role, profiles keep them from clashing. It also forces you to be explicit
> about *which* identity you're using — good hygiene.

### Make the profile the default for this terminal (convenience)

So you don't type `--profile cloudcare` every command:

```bash
# For the current shell session:
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

# To make it permanent for new terminals, append to ~/.bashrc:
echo 'export AWS_PROFILE=cloudcare'   >> ~/.bashrc
echo 'export AWS_REGION=ap-south-1'   >> ~/.bashrc
source ~/.bashrc
```

> 🧠 **Order of precedence (important when debugging "wrong account" issues):**
> environment variables (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`...) **override**
> what's in `~/.aws/*`. Terraform reads credentials the same way the CLI does, so
> whatever the CLI uses, Terraform uses.

---

## 7. Verify the connection (the moment of truth)

```bash
aws sts get-caller-identity
```

Expected output (your numbers/ARN will differ):

```json
{
    "UserId": "AIDA................",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/chalaka-admin"
}
```

This means: "AWS confirms these credentials belong to `chalaka-admin` in account
`123456789012`." If you see this, **you're connected.** 🎉

Quick extra checks:

```bash
# Which Region am I defaulting to? (should print ap-south-1)
aws configure get region

# Can I list S3 buckets? (likely empty — that's fine, it proves auth works)
aws s3 ls
```

**Troubleshooting:**
- `InvalidClientTokenId` / `SignatureDoesNotMatch` → keys typed wrong; re-run
  `aws configure --profile cloudcare`.
- `Unable to locate credentials` → `AWS_PROFILE` not set; run
  `export AWS_PROFILE=cloudcare`.
- Wrong account in the ARN → an env var is overriding your profile; check
  `env | grep AWS`.

---

## 8. Protect secrets in this repo (do this now)

Even though credentials live in `~/.aws/` (outside this folder), we add a
`.gitignore` so we never accidentally commit secrets, state, or build artifacts
later.

Create `/home/chalaka/aws-cloud-deployment/.gitignore` with:

```gitignore
# Never commit credentials or local AWS config
**/.aws/
*.pem
*.key
.env
.env.*

# Terraform local state & caches (we'll use remote state, but just in case)
**/.terraform/
*.tfstate
*.tfstate.*
crash.log
*.tfvars            # may contain secrets; commit *.tfvars.example instead

# Python / Node build junk (for the app later)
__pycache__/
*.pyc
node_modules/
dist/
build/
```

> 🧠 `*.tfstate` can contain secrets in plaintext (like the DB password), so it
> must never be committed. We'll also move state to a remote backend in Doc 06,
> which is the proper fix.

(You don't have to `git init` yet — we'll do that intentionally in a later phase.
The `.gitignore` just needs to exist before you ever do.)

---

## ✅ Checkpoint

You're ready for the next doc when:

- [ ] `aws --version` shows **2.x**.
- [ ] `terraform -version` shows **1.x**.
- [ ] `aws sts get-caller-identity` returns your `chalaka-admin` ARN.
- [ ] `aws configure get region` prints `ap-south-1`.
- [ ] `.gitignore` exists in the project root.

> 💰 Note: nothing you did here costs money. Creating access keys, configuring
> the CLI, and calling `sts get-caller-identity` are all free.

Next: **[05 — Terraform Fundamentals](05-terraform-fundamentals.md)** — learn how
Terraform thinks (state, plan, apply) before we build anything real.
