# 03 — AWS Account & Cost Safety

> **Goal of this doc:** create your AWS account, lock down the dangerous root
> user, create a safe admin identity, and — most importantly — put up **money
> guardrails** so you can never be surprised by a bill. **Do this before
> anything else touches AWS.**

This doc is mostly done in the **AWS Console** (the website), by clicking. That's
fine — account security and billing setup is a one-time thing you do by hand.
From Doc 06 onward, almost everything is Terraform.

⏱️ Time: ~45–60 minutes. Don't rush the security parts.

---

## 0. Understand the AWS Free Tier (so you know what's safe)

The Free Tier has **three kinds** of free, and mixing them up is how people get
billed:

1. **12-months-free** — free for 12 months from signup, then billed. Examples:
   750 hrs/month of `t2.micro` EC2, 750 hrs/month of `db.t3.micro` RDS, 5 GB S3,
   750 hrs/month of an ALB.
2. **Always-free** — free forever within a limit. Examples: 1M Lambda
   requests/month, 25 GB DynamoDB, 1M CloudWatch API requests.
3. **Trials** — free for a short period after first use.

> 💰 **Three traps to remember all project long:**
> - **750 hours ≈ one instance running all month.** Two `t2.micro` running 24/7
>   = ~1,460 hrs = you pay for ~710 of them. So we usually run **one**.
> - **NAT Gateway is NOT free** (~$32/mo + data). We avoid it.
> - **Multi-AZ RDS doubles the hours**, blowing the 750-hr budget. Single-AZ only.
>
> Your "$100" is **promotional credit** that covers small overages, but treat it
> as precious. Our destroy-after-labs habit means you'll likely spend only a few
> dollars across the whole project.

---

## 1. Create the AWS account

1. Go to **https://aws.amazon.com/** and choose **Create an AWS Account**.
2. Enter your email (you can use `chalaka@wso2.com` or a personal one — note that
   work email may have org restrictions; a personal email gives you full control)
   and an **account name** like `chalaka-cloudcare`.
3. Provide contact details (choose **Personal** account type).
4. **Add a payment card.** Yes, even for free tier — AWS requires it to verify
   identity and to bill any overage. Our guardrails make surprise charges very
   unlikely.
5. **Verify your phone** (SMS/call) and pass the captcha.
6. Choose the **Basic support plan** (free). *Do not* pick a paid support plan.
7. Sign in to the **Console** at **https://console.aws.amazon.com/**.

✅ You now have an account and are logged in as the **root user**. This is the
most powerful identity — we'll secure it next and then stop using it.

---

## 2. Set your Region to Mumbai

In the **top-right** of the Console there's a Region selector (it may say
"N. Virginia"). Change it to **Asia Pacific (Mumbai) ap-south-1**.

> 🧠 Most services are *regional*. If you create things in the wrong Region,
> you'll "lose" them (they're just in another Region) and possibly run resources
> you forgot about = cost. Always confirm the Region selector says **Mumbai**.
> (Exceptions: IAM and billing are *global* — Region doesn't matter for those.)

---

## 3. Secure the root user (critical)

The root user can delete the account and bypass most restrictions. Treat it like
the master key to a building.

### 3.1 Enable MFA on root
**MFA (Multi-Factor Authentication)** requires a second factor (a code from your
phone) in addition to your password. Even if your password leaks, an attacker
can't log in without your phone.

1. Click your account name (top-right) → **Security credentials**.
2. Under **Multi-factor authentication (MFA)** → **Assign MFA device**.
3. Choose **Authenticator app** (e.g., Google Authenticator, Authy, Microsoft
   Authenticator on your phone — install one if needed).
4. Scan the QR code with the app, enter two consecutive codes, and finish.

✅ Root now needs your phone to log in.

### 3.2 Do NOT create root access keys
If you ever see "Create access key" for the root user — **don't**. Programmatic
access should never use root. (If a root access key already exists, delete it.)

### 3.3 Put root away
From now on you log in as the **IAM admin user** you create next, *not* root. Only
use root for the rare account-level tasks AWS forces (e.g., changing the support
plan or closing the account).

---

## 4. Create your daily-use IAM admin user

We'll do day-to-day work (and run Terraform) as an IAM identity, not root.

> 🧠 **Why not just use root?** If your daily credentials leak, you want to be
> able to *revoke and recreate* them without losing the account. You can't revoke
> root. Also, IAM lets you scope permissions and see who did what (auditing).

### 4.1 Create the user
1. Console → search **IAM** → open it.
2. **Users** → **Create user**.
3. Username: `chalaka-admin`.
4. ✅ Check **Provide user access to the AWS Management Console**.
5. Choose **I want to create an IAM user**, set a custom password, and (optional)
   uncheck "must reset password."
6. **Next.**

### 4.2 Give it admin permissions (for now)
1. On the permissions step choose **Attach policies directly**.
2. Search and select **`AdministratorAccess`**.
   > 🧠 This is broad on purpose — as the sole learner you need to create
   > everything. In a real team you'd scope this down. We'll discuss least
   > privilege when we create *machine* roles (which we *will* scope tightly).
3. **Next → Create user.**

### 4.3 Enable MFA on this user too
IAM → Users → `chalaka-admin` → **Security credentials** → **Assign MFA device**
→ Authenticator app → scan + verify. (Same process as root.)

### 4.4 Note the sign-in URL
IAM dashboard shows an **account-specific sign-in URL** like
`https://<account-id>.signin.aws.amazon.com/console`. Bookmark it — that's how
you log in as `chalaka-admin`. **Log out of root and log back in as
`chalaka-admin` now.**

✅ **Checkpoint:** You're now operating as a non-root admin with MFA. Root is
secured and parked. We'll create the *programmatic* access key for Terraform in
Doc 04 (separately, so this doc stays focused on safety).

---

## 5. Money guardrails (the most important section)

We set three independent safety nets. Any one of them will warn you; together
they make a surprise bill nearly impossible.

### 5.1 Turn on Free Tier usage alerts + IAM billing access
1. Top-right account name → **Billing and Cost Management**.
2. Left nav → **Billing preferences** (or **Preferences**).
3. Enable:
   - ✅ **Receive AWS Free Tier alerts** — and enter your email. AWS emails you
     when you approach a free-tier limit (e.g., 85% of 750 EC2 hours).
   - ✅ **Receive CloudWatch billing alerts** (lets us make a billing alarm).
4. Also enable **IAM user and role access to Billing information** (so your
   `chalaka-admin` user — not just root — can see billing).

### 5.2 Create a Budget with email alerts
A **Budget** watches your spend/forecast and emails you at thresholds.

1. Billing console → **Budgets** → **Create budget**.
2. Choose **Customize (advanced)** → **Cost budget**.
3. Name: `monthly-hard-cap`.
4. Period: **Monthly**, Budget amount: **`5` USD** (a deliberately low tripwire —
   you can raise it later; we want to hear about *any* real spend).
5. **Configure alerts** — add three thresholds:
   - **50%** of budgeted amount, **Actual** spend → email you.
   - **80%** of budgeted, **Actual** → email you.
   - **100%** of **Forecasted** amount → email you (catches runaway trends early).
6. Enter your email for each. **Create budget.**

> 🧠 "Actual" alerts fire on money already spent; "Forecasted" alerts predict the
> month-end total from current trends — so you hear about a leak on day 2, not
> day 30.

### 5.3 Create a CloudWatch billing alarm (belt *and* suspenders)
Billing metrics live only in **`us-east-1`**, so switch the Region selector to
**N. Virginia (us-east-1)** *just for this step*, then switch back to Mumbai.

1. Console → **CloudWatch** → **Alarms** → **All alarms** → **Create alarm**.
2. **Select metric** → **Billing** → **Total Estimated Charge** → **USD** →
   select it → **Select metric**.
3. Statistic **Maximum**, Period **6 hours**.
4. Condition: **Greater than** **`5`** (USD).
5. Notification: **Create new SNS topic** named `billing-alarm-topic`, enter your
   email. (You'll get a confirmation email — **click the link to confirm the
   subscription**, or you won't receive alerts.)
6. Name the alarm `billing-over-5-usd` → **Create alarm**.
7. **Switch the Region back to Mumbai (`ap-south-1`).**

✅ **Checkpoint — money safety in place:**
- [ ] Free Tier usage alerts ON (email set).
- [ ] Budget `monthly-hard-cap` at $5 with 50/80/100% alerts.
- [ ] CloudWatch `billing-over-5-usd` alarm created **and SNS email confirmed**.
- [ ] You know where **Billing → Free Tier** is to check usage weekly.

> 💡 If *any* of these ever emails you, **stop and investigate the same day.** The
> usual culprits: a forgotten NAT Gateway, an instance left running, an
> Elastic IP not attached to anything, or RDS left on Multi-AZ.

---

## 6. A few good habits

- **Always check the Region selector says Mumbai** before creating things.
- **Tag everything** with `Project = cloudcare` (Terraform will do this
  automatically) so you can find and bulk-delete project resources.
- **Run `terraform destroy`** at the end of a lab session.
- **Weekly:** open **Billing → Free Tier** and skim the usage bars.
- **Never** paste your access keys into a website, screenshot, or git commit.

---

## 7. Common beginner cost mistakes (forewarned)

| Mistake | Result | Avoid by |
|--------|--------|----------|
| Leaving a NAT Gateway up | ~$1+/day silently | We don't create one; if a lab does, destroy it |
| Two `t2.micro` 24/7 | Exceed 750 free hrs | Run one; scale to two only briefly |
| RDS Multi-AZ left on | Double DB hours | Single-AZ default; flip Multi-AZ off after demo |
| Unattached Elastic IP | ~$0.005/hr each | Release EIPs you're not using |
| Wrong Region orphans | Forgotten running resources | Always verify Mumbai |
| Not running `destroy` | Slow credit drain | End every session with `terraform destroy` |

---

## ✅ Checkpoint

You're ready for the next doc when:

- Root has MFA and is parked; you log in as `chalaka-admin` (also MFA).
- Region is set to **Mumbai**.
- Budget + billing alarm + free-tier alerts are live and the SNS email is
  **confirmed**.

Next: **[04 — Tooling Setup](04-tooling-setup.md)** — install the AWS CLI and
Terraform on your Linux machine and connect them to this account *safely*.
