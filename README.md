# eks_deploy_sample — Spring Boot on Amazon EKS

A small web app that answers at `/hello`, deployed to **Amazon EKS** (Kubernetes on AWS) in two ways:

| | **Part 1 — Deploy by hand** | **Part 2 — CI/CD pipeline** |
|---|---|---|
| **Who runs it** | You, one script per step | GitHub, automatically |
| **When** | Whenever you run the scripts | Every time a pull request is merged into `main` |
| **Good for** | Learning each step, first-time setup, experiments | Day-to-day team work: every merged change reaches production on its own, with tests, rollback, and email alerts |

Start with **Part 1**: it creates the AWS pieces that Part 2 builds on.

---

## Contents

- [Words used in this guide](#words-used-in-this-guide)
- [How it fits together](#how-it-fits-together)
- [What's in this project](#whats-in-this-project)
- **[Part 1 — Deploy by hand: from your Mac to EKS](#part-1--deploy-by-hand-from-your-mac-to-eks)**
  - [1.1 Install the tools](#11-install-the-tools)
  - [1.2 Connect your Mac to AWS](#12-connect-your-mac-to-aws)
  - [1.3 Run the app on your Mac](#13-run-the-app-on-your-mac)
  - [1.4 Upload the app to AWS (ECR)](#14-upload-the-app-to-aws-ecr)
  - [1.5 Create the Kubernetes cluster](#15-create-the-kubernetes-cluster)
  - [1.6 Deploy the app to the cluster](#16-deploy-the-app-to-the-cluster)
  - [1.7 Test it](#17-test-it)
  - [1.8 Release a new version](#18-release-a-new-version)
  - [1.9 Clean up (stop paying)](#19-clean-up-stop-paying)
  - [Part 1 troubleshooting](#part-1-troubleshooting)
- **[Part 2 — CI/CD pipeline: automatic test and deploy](#part-2--cicd-pipeline-automatic-test-and-deploy)**
  - [2.1 How the pipeline works](#21-how-the-pipeline-works)
  - [2.2 One-time setup](#22-one-time-setup)
  - [2.3 Everyday use: making a change](#23-everyday-use-making-a-change)
  - [2.4 Email alerts](#24-email-alerts)
  - [2.5 Demo: three scenarios](#25-demo-three-scenarios)
  - [Part 2 troubleshooting](#part-2-troubleshooting)
- [Next things to do](#next-things-to-do)

---

## Words used in this guide

| Word | Plain meaning |
|---|---|
| **Docker image** | The app packed into one box with everything it needs to run. Build it once, run it anywhere. |
| **ECR** (Elastic Container Registry) | AWS's storage for Docker images. Like a shelf where the boxes wait to be used. |
| **EKS** (Elastic Kubernetes Service) | AWS's managed **Kubernetes**: a system that runs your app on servers, keeps it running, and replaces copies that crash. |
| **Cluster** | The group of servers Kubernetes manages for you. Here: 2 servers (*nodes*). |
| **Pod** | One running copy of the app. This project runs 2 so one can fail without downtime. |
| **Load balancer** | The public front door. It gets an internet address and spreads visitors across the pods. |
| **Tag** | A label on an image, like `v1` or a commit ID, so you can tell versions apart. |
| **Branch / pull request (PR)** | A branch is a private copy of the code to work on. A PR asks to merge it into `main` and lets others review it. |
| **CI** (Continuous Integration) | Automatic checks on every PR: does it build, do the tests pass? |
| **CD** (Continuous Deployment) | Automatically shipping each merged change to production. |
| **SNS** | AWS's notification service. Here it sends the alert emails. |

---

## How it fits together

```
 Your Mac (build)          AWS (us-west-1)
 ┌──────────────┐  push   ┌───────────────────┐  pull   ┌──────────────────── EKS cluster ─────────────────────┐
 │ mvn + docker │ ──────▶ │        ECR        │ ──────▶ │  Deployment: eks-deploy-sample (2 pods)              │
 └──────────────┘         │ eks-deploy-sample │         │            ▲                                         │
  (or GitHub, in Part 2)  └───────────────────┘         │  Service: eks-deploy-sample-svc (LoadBalancer :80)   │
                                                        └────────────┼─────────────────────────────────────────┘
                                                     curl http://<load-balancer-address>/hello
```

In words: the app is **packaged** into a Docker image, **uploaded** to ECR, and **run** by the EKS cluster, which puts a public load balancer in front of it.

---

## What's in this project

```
eks_deploy_sample/
├── src/main/java/.../EksDeploySampleApplication.java   # The app: /hello returns a greeting, a version, and which pod answered
├── src/main/resources/application.yml                 # App settings (port 8080, health checks for Kubernetes)
├── src/test/java/.../EksDeploySampleApplicationTests.java  # Automatic tests (run by CI)
├── pom.xml                                            # Java build settings (Spring Boot 3.5, Java 21)
├── Dockerfile                                         # How to package the app into a Docker image
├── k8s/app.yaml                                       # Instructions for Kubernetes: run 2 pods + a load balancer
├── scripts/                                           # One script per step of Part 1 (every line is commented)
│   ├── run-local.sh          # 1.3  Build and run the app in Docker on your Mac
│   ├── env.sh                # 1.4  Shared settings for your terminal (use with: source)
│   ├── push-to-ecr.sh        # 1.4  Build the image and upload it to ECR
│   ├── create-cluster.sh     # 1.5  Create the EKS cluster
│   ├── deploy.sh             # 1.6  Deploy an image version to the cluster
│   ├── test-app.sh           # 1.7  Call the live app and fail if it doesn't answer
│   ├── clean-up.sh           # 1.9  Delete the app and the cluster
│   └── shut-down-docker.sh   # 1.9  Stop containers and quit Docker Desktop
└── .github/workflows/                                 # Part 2: the pipeline
    ├── ci.yml                # On every pull request: build, test, build image; email if it fails
    └── cd.yml                # On every merge to main: upload, deploy, test; email on success; roll back + email on failure
```

---

# Part 1 — Deploy by hand: from your Mac to EKS

You run one script per step, in order. Each step says **what it does**, **what to run**, and **what you should see**.

**Quick version** (after 1.1 and 1.2 are done, Docker Desktop is running, and you're in the project folder):

```bash
chmod +x scripts/*.sh                  # first time only: allow the scripts to run

./scripts/run-local.sh                 # 1.3  try the app on your Mac (Ctrl+C to stop)
source ./scripts/env.sh                # 1.4  load settings into this terminal
./scripts/push-to-ecr.sh v1            # 1.4  upload version v1 to ECR
./scripts/create-cluster.sh            # 1.5  create the cluster (~15–20 min, starts billing)
./scripts/deploy.sh v1                 # 1.6  run v1 on the cluster
./scripts/test-app.sh                  # 1.7  call the live app

./scripts/push-to-ecr.sh v2            # 1.8  after changing the code: upload v2 ...
./scripts/deploy.sh v2                 #      ... and switch the cluster to it

./scripts/clean-up.sh                  # 1.9  delete the app and the cluster
./scripts/shut-down-docker.sh          # 1.9  stop Docker on your Mac
```

---

## 1.1 Install the tools

| Tool | What it's for | Install (macOS) | Check it works |
|---|---|---|---|
| Java 21 + Maven | Build the app | `brew install openjdk@21 maven` | `java -version && mvn -v` |
| Docker Desktop | Package and run the app | [docker.com](https://www.docker.com/products/docker-desktop/) | `docker info` |
| AWS CLI v2 | Talk to AWS from the terminal | `brew install awscli` | `aws --version` |
| eksctl | Create and delete EKS clusters | `brew tap eksctl-io/eksctl && brew install eksctl-io/eksctl/eksctl` | `eksctl version` |
| kubectl | Talk to Kubernetes | `brew install kubectl` | `kubectl version --client` |
| GitHub CLI (Part 2) | Work with GitHub from the terminal | `brew install gh` | `gh auth status` |

> Use a **release** build of eksctl (a plain version number), not a `-dev` build.

---

## 1.2 Connect your Mac to AWS

**What:** creates a safe everyday login for AWS. Never use the account's *root* (owner) keys.

**In the AWS Console** (signed in as root, one last time):
1. **IAM → Users → Create user** → name it `naveen-admin`.
2. **Attach policies directly** → select **AdministratorAccess** → **Create user**.
3. Open the user → **Security credentials** → **Create access key** → use case **CLI** → **download the .csv** (the secret is shown only once).
4. Turn on **MFA for the root user** (account menu → Security credentials), then sign out of root for good.

**On your Mac:**

```bash
aws configure
#   Access Key ID:      (from the csv)
#   Secret Access Key:  (from the csv)
#   Default region:     us-west-1
#   Output format:      json

aws sts get-caller-identity   # should end in user/naveen-admin, not root
```

---

## 1.3 Run the app on your Mac

**What:** builds the app, packs it into a Docker image, and runs it on your Mac, so you can see it work before anything touches AWS.

**Before you start:** open Docker Desktop and wait until it says it's running.

```bash
./scripts/run-local.sh                 # or: PORT=9090 ./scripts/run-local.sh if 8080 is busy
```

In a second terminal:

```bash
curl localhost:8080/hello
curl localhost:8080/actuator/health/readiness
```

**You should see:** something like `{"greeting":"Hello from EKS ...","version":"v1","pod":"Your-Mac.local"}` and `{"status":"UP"}`.

Press **Ctrl+C** in the first terminal to stop. The container is removed automatically.

<details>
<summary>What's inside: the app, its settings, and the Dockerfile</summary>

- **`EksDeploySampleApplication.java`** — `/hello` returns a greeting, a version, and the name of the pod that answered, so you can see the load balancer spreading requests.
- **`application.yml`** — runs on port 8080, shuts down gracefully, and turns on the `/actuator/health/liveness` and `/readiness` checks Kubernetes uses.
- **`Dockerfile`** (capital **D**: Linux is case-sensitive):
  ```dockerfile
  FROM eclipse-temurin:21-jre
  WORKDIR /app
  COPY target/*.jar app.jar
  EXPOSE 8080
  ENTRYPOINT ["java", "-jar", "app.jar"]
  ```
- Without Docker: `mvn clean package -DskipTests && java -jar target/eks_deploy_sample.jar`
</details>

---

## 1.4 Upload the app to AWS (ECR)

**What:** builds an image that runs on AWS's servers and uploads it to ECR with a version **tag** (`v1`, `v2`, …).

**1. Load the shared settings into your terminal:**

```bash
source ./scripts/env.sh     # prints AWS_REGION, ACCOUNT_ID, REPO, IMAGE_BASE; none should be blank
```

> These settings only last for the **current terminal tab**. In a new tab, run `source ./scripts/env.sh` again before any later step.

**2. Build and upload version v1:**

```bash
./scripts/push-to-ecr.sh v1
```

The script creates the ECR repository if needed, logs Docker in to ECR, builds the image for AWS's servers (`linux/amd64`), and uploads it.

**You should see:** the last line lists the tags in ECR, including `v1`.

> **The tag is required.** Use a **new** tag for every release (`v1`, `v2`, `v3` …). Reusing a tag makes rollouts unreliable.

---

## 1.5 Create the Kubernetes cluster

**What:** creates the servers and the Kubernetes service that will run the app. **Takes about 15–20 minutes and starts AWS billing** (about $0.10/hour for EKS, plus the 2 servers).

**1. Pick a server type your account allows.** New accounts on AWS's **Free plan** can only use certain types. List them:

```bash
aws ec2 describe-instance-types --region us-west-1 \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
  --output table
```

Pick the largest x86 option, for example `m7i-flex.large` (the default) or `c7i-flex.large`. Paid accounts can use `t3.medium`.

**2. Create the cluster:**

```bash
./scripts/create-cluster.sh                                # uses m7i-flex.large
NODE_TYPE=c7i-flex.large ./scripts/create-cluster.sh       # or choose another type
```

**You should see:** at the end, `kubectl get nodes` lists **2 nodes** with STATUS **Ready**.

- Running it again is safe: if the cluster exists, it skips creation and just reconnects `kubectl`.
- A yellow `[!]` warning about **OIDC** / `vpc-cni` is safe to ignore.

<details>
<summary>What gets created</summary>

A private network (VPC), the Kubernetes control plane, 2 servers (EC2 *nodes*), Kubernetes' core add-ons, and an entry in `~/.kube/config` so `kubectl` talks to the new cluster.
</details>

---

## 1.6 Deploy the app to the cluster

**What:** tells Kubernetes to run a version of your app, using the instructions in `k8s/app.yaml`.

```bash
./scripts/deploy.sh v1
```

**You should see:** after 1–2 minutes, 2 pods at `1/1 Running`, and a Service whose `EXTERNAL-IP` is a long `...elb.amazonaws.com` address (it may say `<pending>` for a minute).

> The version must already be in ECR (uploaded in 1.4).

<details>
<summary>What <code>k8s/app.yaml</code> asks for, in plain words</summary>

| Part | Plain meaning |
|---|---|
| **Deployment**, 2 replicas | Always keep 2 copies (pods) of the app running; replace any that crash |
| `image: IMAGE_URI` | Which version to run. `deploy.sh` fills in the real ECR address and tag. |
| `resources` | How much CPU and memory each copy needs |
| `readinessProbe` | Only send visitors to a copy once `/actuator/health/readiness` says UP |
| `livenessProbe` | Restart a copy if `/actuator/health/liveness` stops answering |
| **Service**, `LoadBalancer` | Create a public AWS load balancer: port 80 → the app's port 8080 |

Don't run `kubectl apply -f k8s/app.yaml` directly: the `IMAGE_URI` placeholder would give `InvalidImageName`. Always use `deploy.sh`.
</details>

---

## 1.7 Test it

**What:** finds the load balancer's public address and calls the live app.

```bash
./scripts/test-app.sh
```

**You should see:** the address, then a reply such as:

```json
{"greeting":"Hello from EKS ...","version":"v1","pod":"eks-deploy-sample-cc445fbd6-4pzg7"}
```

- Right after the first deploy, the address can take **2–3 minutes** to start working. The script keeps retrying for about 2.5 minutes, and fails if the app never answers.
- Run it a few times: the `pod` name changes between the two copies. That's the load balancer sharing the work.

**See it in the AWS console** (region **us-west-1**, signed in as `naveen-admin`, not root):
- **The app's Service:** EKS → Clusters → `eks-sample-cluster` → **Resources** → Service and networking → Services → `eks-deploy-sample-svc`.
- **The load balancer:** EC2 → Load Balancers. Its **DNS name** matches the address the script printed.

---

## 1.8 Release a new version

**What:** ships a change with **zero downtime**: Kubernetes swaps the copies one at a time and only sends visitors to a new copy once it's healthy.

**1. Change the code** in `src/main/java/com/example/eksdeploysample/EksDeploySampleApplication.java`, for example:

```java
"greeting", "Hello from EKS - updated!",
"version", "v2",
```

**2. (Optional) Watch it switch live.** In a second terminal:

```bash
export URL=$(kubectl get svc eks-deploy-sample-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $URL    # must NOT be blank
while true; do curl -s http://$URL/hello; echo; sleep 1; done      # Ctrl+C to stop
```

**3. Upload and deploy the new version:**

```bash
./scripts/push-to-ecr.sh v2
./scripts/deploy.sh v2
```

**You should see:** the replies change from `v1` to `v2` with no errors in between.

**Undo** if the new version misbehaves:

```bash
kubectl rollout undo deployment/eks-deploy-sample
```

> **Use the same tag on both commands.** `push-to-ecr.sh` only uploads; the cluster only changes when you run `deploy.sh` with that tag.

---

## 1.9 Clean up (stop paying)

**What:** deletes the app, its load balancer, and the cluster, then checks nothing is left that costs money.

```bash
./scripts/clean-up.sh          # ~10–15 min
```

**You should see:** the "Remaining clusters" and "Remaining load balancers" sections print nothing.

- The images in ECR are **kept** (storage costs very little). To delete them too, uncomment the `aws ecr delete-repository` line in `scripts/clean-up.sh`.
- Part 2's pipeline needs the cluster. After deleting it, CD deploys fail until you recreate it (and redo step 6 of 2.2).

**Stop Docker on your Mac** when you're done:

```bash
./scripts/shut-down-docker.sh
```

---

## Part 1 troubleshooting

| Problem | Why | Fix |
|---|---|---|
| `SignatureDoesNotMatch` on any `aws` command | The secret key doesn't match the access key | Check `env | grep AWS` for overrides (`unset` them), check `cat -e ~/.aws/credentials` for stray characters, or create a new access key and run `aws configure` again |
| `500 Internal Server Error ... docker.sock` | Docker Desktop's engine isn't healthy | `osascript -e 'quit app "Docker"'; sleep 5; open -a Docker`, then wait for "running". Still stuck: Docker Desktop → Troubleshoot → Restart. |
| `bind: address already in use` from `run-local.sh` | Something else uses port 8080, often an earlier `java -jar` | `lsof -nP -iTCP:8080 -sTCP:LISTEN` to find it, then stop it, or use `PORT=9090 ./scripts/run-local.sh` |
| `argument --region: expected one argument` | This terminal doesn't have the settings | `source ./scripts/env.sh` |
| `zsh: parse error near '\n'` | A pasted command still had a `<...>` placeholder | Replace the whole placeholder, brackets included, with the real value |
| `zsh: bad substitution` | Bash-only syntax pasted into zsh | Use the zsh form, or run it with `bash -c '...'` |
| Pods show `InvalidImageName` | The image address was blank | Run `./scripts/deploy.sh <tag>` again |
| Pods show `ErrImagePull` / `ImagePullBackOff` | That tag isn't in ECR | Check with `aws ecr list-images --repository-name eks-deploy-sample --region us-west-1`, push it with `./scripts/push-to-ecr.sh <tag>`, then deploy again |
| `test-app.sh` says `Empty reply from server` | No healthy pod behind the load balancer | `kubectl get pods`: both should be `1/1 Running`. Fix the pods first. |
| Cluster creation stuck in `CREATING`, then times out | Usually AWS refusing the server type (Free plan) | See below |

**Finding why cluster creation failed.** CloudTrail keeps 90 days of AWS history, even after the cluster is deleted. Put your own times in place of the two example times:

```bash
aws cloudtrail lookup-events --region us-west-1 \
  --start-time 2026-09-30T18:00:00Z --end-time 2026-09-30T20:00:00Z --output json | python3 -c '
import json, sys
for e in json.load(sys.stdin)["Events"]:
    d = json.loads(e["CloudTrailEvent"])
    if "errorCode" in d:
        print(d["eventTime"], d["eventSource"], d["eventName"], d["errorCode"], d.get("errorMessage", "")[:200])'
```

Our root cause was `RunInstances → "The specified instance type is not eligible for Free Tier."` Fix: pick a free-tier-eligible type (1.5) or upgrade the account to the Paid plan. A `--dry-run` test does **not** catch this.

**Handy commands:**

```bash
kubectl get pods -w                           # live pod status (Ctrl+C to stop)
kubectl describe pod POD_NAME | tail -20      # why a pod won't start
kubectl logs POD_NAME                         # the app's own log
kubectl get events --sort-by=.lastTimestamp   # recent cluster events
```

---

# Part 2 — CI/CD pipeline: automatic test and deploy

Once this is set up, **nobody runs the Part 1 scripts by hand**. A developer opens a pull request, GitHub checks it, a teammate reviews it, and merging it ships it to production, with an email either way.

## 2.1 How the pipeline works

```
 feature branch ──▶ pull request ──▶ CI: build + test ──▶ review ──▶ merge to main
                          │                                               │
                    CI fails? email,                                     CD: upload ─▶ deploy ─▶ test
                    merge is blocked                                      │
                                                     works? "Deploy succeeded" email
                                                     fails? roll back + "Deploy FAILED" email
```

| | **CI** (`.github/workflows/ci.yml`) | **CD** (`.github/workflows/cd.yml`) |
|---|---|---|
| **Runs when** | A pull request to `main` is opened or updated | A pull request is merged into `main` |
| **Does** | Builds the app, runs the tests, builds the Docker image | Uploads the image to ECR, deploys it, tests the live app |
| **Uploads or deploys?** | No | Yes |
| **On success** | The PR can be merged | "Deploy succeeded" email |
| **On failure** | The PR can't be merged; "CI FAILED" email | Rolls back to the last good version; "Deploy FAILED" email |

**Good to know:**
- **The cluster must already exist** (Part 1, step 1.5). CD deploys to it but never creates or deletes it.
- **Version tag = commit ID** (like `3c43352`), set automatically. Every image in ECR matches exactly one commit, so developers never clash over `v1`/`v2`.
- **One deploy at a time.** If two PRs are merged close together, the second waits.
- **Time limits:** upload 15 min, deploy 10 min, live test 5 min. Running over counts as a failure.
- **No AWS passwords are stored in GitHub.** Each run gets short-lived AWS access through **OIDC** (a trust link between GitHub and AWS).
- **Where to watch:** the repo's **Actions** tab on GitHub.

---

## 2.2 One-time setup

Do these in order, in **one terminal**, from the project folder. Steps 2–9 are done **once**. Only step 6 is repeated, each time you recreate the cluster.

**1. Set the names used below.**

```bash
export AWS_REGION=us-west-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GH_REPO=naveenkrishnan01/EKS_DEPLOY_DEMO
export CLUSTER=eks-sample-cluster
export ROLE_NAME=github-actions-eks-deploy
export ALERT_EMAIL=naveenkrishnan99@yahoo.com
echo "$ACCOUNT_ID"    # must NOT be blank
```

**2. Let AWS trust GitHub's login service** (once per AWS account).

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

> "Already exists" is fine. If it asks for a thumbprint, add `--thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1`.
> In the console: IAM → Identity providers → Add provider → OpenID Connect, URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.

**3. Create the deploy role** that CD uses. Only runs on this repo's `main` branch can use it.

GitHub identifies the repo with a *subject*. Newer repos include ID numbers (for example `repo:naveenkrishnan01@1700446/EKS_DEPLOY_DEMO@1396760023`), and the role must match it exactly. Ask GitHub for it:

```bash
export SUB_PREFIX=$(gh api "repos/${GH_REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')
export SUB_PREFIX=${SUB_PREFIX:-repo:${GH_REPO}}
echo "$SUB_PREFIX"
```

Then create the role:

```bash
cat > /tmp/gha-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "${SUB_PREFIX}:ref:refs/heads/main"
      }
    }
  }]
}
EOF

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/gha-trust.json \
  --query Role.Arn --output text
```

**4. Create the email alerts topic** and subscribe the alert address.

```bash
export TOPIC_ARN=$(aws sns create-topic --name eks-deploy-alerts --region "$AWS_REGION" --query TopicArn --output text)
echo "$TOPIC_ARN"     # must NOT be blank

aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
  --notification-endpoint "$ALERT_EMAIL" --region "$AWS_REGION"
```

**Then open the "AWS Notification - Subscription Confirmation" email and click _Confirm subscription_.** No alerts arrive until you do. Check Spam too.

**5. Give the deploy role only what CD needs:** upload to the one ECR repository, find the cluster, and send to the one alerts topic.

```bash
cat > /tmp/gha-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Effect": "Allow",
      "Action": [
        "ecr:DescribeRepositories", "ecr:CreateRepository", "ecr:ListImages", "ecr:DescribeImages",
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/eks-deploy-sample" },
    { "Effect": "Allow", "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}" },
    { "Effect": "Allow", "Action": "sns:Publish", "Resource": "${TOPIC_ARN}" }
  ]
}
EOF

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name eks-deploy-pipeline \
  --policy-document file:///tmp/gha-permissions.json
```

**6. Let the deploy role into the cluster.** The cluster must be running. **Repeat this every time you recreate the cluster.**

```bash
# Should print API or API_AND_CONFIG_MAP
aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" --query cluster.accessConfig.authenticationMode --output text

# Add the role to the cluster's access list
aws eks create-access-entry --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# Allow it to change apps in the "default" area (namespace) only
aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=default
```

> If the first command prints `CONFIG_MAP`, run `aws eks update-cluster-config --name "$CLUSTER" --region "$AWS_REGION" --access-config authenticationMode=API_AND_CONFIG_MAP`, wait a minute, then continue.
> In the console: EKS → `eks-sample-cluster` → **Access** tab → **Create access entry**, role ARN, policy `AmazonEKSEditPolicy`, scope *Kubernetes Namespace* `default`.

**7. Create the alerts-only role** that CI uses to email failures. CI runs code nobody has reviewed yet, so this role can **only send to the alerts topic**: no ECR, no cluster.

```bash
cat > /tmp/gha-ci-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "${SUB_PREFIX}:pull_request"
      }
    }
  }]
}
EOF

cat > /tmp/gha-ci-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": "sns:Publish", "Resource": "${TOPIC_ARN}" }]
}
EOF

aws iam create-role --role-name github-actions-ci-alerts \
  --assume-role-policy-document file:///tmp/gha-ci-trust.json --query Role.Arn --output text
aws iam put-role-policy --role-name github-actions-ci-alerts --policy-name ci-alerts-only \
  --policy-document file:///tmp/gha-ci-permissions.json
```

**8. Tell GitHub the three names.** Repo → **Settings** → **Secrets and variables** → **Actions** → **Variables** tab → **New repository variable**, once for each. They're *variables*, not secrets: these names aren't passwords.

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<your account ID>:role/github-actions-eks-deploy` |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-west-1:<your account ID>:eks-deploy-alerts` |
| `CI_ALERT_ROLE_ARN` | `arn:aws:iam::<your account ID>:role/github-actions-ci-alerts` |

Copy the names exactly, and make sure no space slips in before or after a value. From the terminal instead:

```bash
gh variable set AWS_ROLE_ARN      --repo "$GH_REPO" --body "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
gh variable set SNS_TOPIC_ARN     --repo "$GH_REPO" --body "$TOPIC_ARN"
gh variable set CI_ALERT_ROLE_ARN --repo "$GH_REPO" --body "arn:aws:iam::${ACCOUNT_ID}:role/github-actions-ci-alerts"
gh variable list --repo "$GH_REPO"       # all three should be listed
```

**9. Protect `main`** so code only gets there through a pull request with passing CI. In the browser:

1. Open one pull request first, so GitHub has seen the **`build`** check run.
2. Repo → **Settings** → **Rules** → **Rulesets** → **New ruleset** → **New branch ruleset**.
3. **Name:** `protect-main`. **Enforcement status:** Active. **Target branches:** Add target → *Include default branch*.
4. Tick: **Restrict deletions**, **Require a pull request before merging** (required approvals **1**), **Require status checks to pass** → Add checks → **`build`**, **Block force pushes**.
5. **Create**.

> Working alone? GitHub won't let you approve your own pull request. Set required approvals to **0** until a second person joins, and keep the `build` check required.

**Check everything works:**

```bash
aws sns publish --topic-arn "$TOPIC_ARN" --region "$AWS_REGION" \
  --subject "Test alert" --message "If you can read this, deploy alerts work."
```

The email should arrive within a minute.

---

## 2.3 Everyday use: making a change

1. **Start a branch** from the latest `main`:
   ```bash
   git switch main && git pull
   git switch -c my-change
   ```
2. **Make the change** and check it locally (optional): `mvn -q verify`.
3. **Push and open a pull request:**
   ```bash
   git commit -am "Describe the change"
   git push -u origin my-change
   gh pr create --fill
   ```
4. **Wait for CI** to show a green **build** check on the PR (`gh pr checks --watch`). A red check blocks the merge and sends a "CI FAILED" email.
5. **Review and merge** on GitHub (**Merge pull request** → **Confirm merge**), or `gh pr merge --squash --delete-branch`.
6. **CD runs by itself.** Watch it in the **Actions** tab or with `gh run watch`. When it's done, you get a "Deploy succeeded" email and `./scripts/test-app.sh` shows the change.

**What runs where:** CI and CD run on GitHub's own temporary computers, not on your Mac. Nothing appears in Docker Desktop. The only lasting copy of each image is the one CD uploads to **your** ECR, tagged with the commit ID.

---

## 2.4 Email alerts

| Email | When | Sent by | Goes to |
|---|---|---|---|
| **CI FAILED** | A pull request's build or tests fail | SNS (from CI) | `naveenkrishnan99@yahoo.com` |
| **Deploy succeeded** | CD deployed and the live test passed | SNS (from CD) | `naveenkrishnan99@yahoo.com` |
| **Deploy FAILED** | CD failed or timed out (and rolled back) | SNS (from CD) | `naveenkrishnan99@yahoo.com` |
| GitHub's "workflow failed" | Any failed run | GitHub | your GitHub account email (`naveenkrishnan01@gmail.com`) |

- SNS emails come from **no-reply@sns.amazonaws.com**. If they're missing, look in **Spam/Bulk**, mark one **Not spam**, and add the address to your contacts.
- GitHub's own email is the backup for the one case SNS can't cover: when the AWS login itself fails. It's controlled in GitHub → **Settings** → **Notifications** → **Actions**.
- To change where SNS emails go: AWS console → **SNS** → Topics → `eks-deploy-alerts` → **Create subscription** (Email) for the new address, confirm it, then delete the old subscription.

---

## 2.5 Demo: three scenarios

Shows the pipeline **blocking a bad change**, then **shipping good ones** to production.

**Before the demo:**
- The cluster is running (`./scripts/create-cluster.sh`) and step 6 of 2.2 has been done on it.
- Two terminals open in the project folder. In **Terminal 2**, watch the live app (Ctrl+C to stop):
  ```bash
  export URL=$(kubectl get svc eks-deploy-sample-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  echo $URL    # must NOT be blank
  while true; do curl -s http://$URL/hello; echo; sleep 2; done
  ```
  It shows what production serves right now, for example `{"greeting":"Hello from EKS ...","version":"v1","pod":"..."}`.

### Scenario 1 — Code changes but the test doesn't: CI fails, merge is blocked

**Goal:** show broken code can't reach production.

1. Create the branch:
   ```bash
   git switch main && git pull
   git switch -c feature-a
   ```
2. In `src/main/java/com/example/eksdeploysample/EksDeploySampleApplication.java`, rename the reply's **key** from `"greeting"` to `"reply"`. Leave the test file alone: it still expects `"greeting"`.
   ```java
   "reply", "Hello from EKS ...",
   ```
   > Changing only the **text** wouldn't fail: the test checks that the key exists, not the wording.
3. (Optional) See it fail locally: `mvn -q verify`.
4. Push and open a PR:
   ```bash
   git commit -am "Rename greeting to reply (test not updated)"
   git push -u origin feature-a
   gh pr create --fill
   ```
5. **Show:** the PR's **build** check turns red ❌ and **Merge** is disabled. The failed check's **Build and test** log says:
   ```
   [/hello should return a message]
   Expecting actual: "{"reply":"Hello from EKS ...", ...}" to contain: ""greeting""
   ```
   A **"CI FAILED"** email arrives. **Terminal 2 is unchanged**: nothing was deployed.

### Scenario 2 — Fix the test: CI passes, CD deploys, the change is live

**Goal:** show the same PR going green and reaching production by itself.

1. On the same branch, in `src/test/java/com/example/eksdeploysample/EksDeploySampleApplicationTests.java`, make the test expect the new key:
   ```java
   assertThat(response.getBody()).as("/hello should return a reply").contains("\"reply\"");
   ```
2. Push the fix:
   ```bash
   git commit -am "Update test for reply key"
   git push
   gh pr checks --watch        # build: pass
   ```
3. Merge (button on GitHub, or `gh pr merge --squash --delete-branch`), then watch CD: `gh run watch`.
4. **Show:**
   - **Terminal 2** changes from `{"greeting": ...}` to `{"reply": ...}` with no errors in between.
   - `./scripts/test-app.sh` returns the new reply.
   - A **"Deploy succeeded"** email arrives with the commit ID.
   - The running version equals the merge commit:
     ```bash
     git switch main && git pull && git log --oneline -1
     kubectl get deploy eks-deploy-sample -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
     ```

### Scenario 3 — An everyday change: the new pods serve the latest code

**Goal:** show the normal flow end to end, with proof that **new** pods replaced the old ones.

1. Note the current pods: `kubectl get pods -l app=eks-deploy-sample` (names and AGE).
2. New branch and change:
   ```bash
   git switch main && git pull
   git switch -c feature-b
   ```
   ```java
   "reply", "Hello from EKS - deployed by CI/CD!",
   "version", "v4",
   ```
   No test change needed: the key is still `"reply"`.
3. Push, open the PR, wait for green, merge:
   ```bash
   git commit -am "New reply text, version v4"
   git push -u origin feature-b
   gh pr create --fill
   gh pr checks --watch
   gh pr merge --squash --delete-branch
   gh run watch
   ```
4. **Show:**
   - **Terminal 2** switches to `{"reply":"Hello from EKS - deployed by CI/CD!","version":"v4", ...}`.
   - `kubectl get pods -l app=eks-deploy-sample` shows **new** pod names with a young AGE.
   - The `pod` in each reply matches one of those new names.
   - A second **"Deploy succeeded"** email.

**After the demo:** Ctrl+C in Terminal 2, then `./scripts/clean-up.sh`.

---

## Part 2 troubleshooting

| Problem (in the Actions log) | Why | Fix |
|---|---|---|
| `refusing to allow an OAuth App to create or update workflow` when pushing | Your GitHub login can't change workflow files yet | `gh auth refresh -h github.com -s workflow`, enter the code in the browser, push again |
| `Could not assume role` / `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The role's trust rule doesn't match GitHub's subject (usually the ID-number format), the `AWS_ROLE_ARN` variable is wrong (check for a space), or the run wasn't on `main` | Redo step 3 with `SUB_PREFIX`, or in the console: IAM → Roles → role → **Trust relationships** → edit the `sub` line. Check step 8. |
| `You must be logged in to the server (Unauthorized)` | The cluster doesn't know the deploy role, usually after recreating it | Redo step 6 |
| `ResourceNotFoundException ... eks-sample-cluster` | The cluster isn't running | `./scripts/create-cluster.sh`, then step 6 |
| `AccessDenied ... sns:Publish` | The topic in GitHub doesn't match the role's permission | Redo steps 5 and 8 with the same topic |
| CI's **Log in to AWS for the alert** fails | `CI_ALERT_ROLE_ARN` missing or wrong, or the CI role's trust doesn't end in `:pull_request` | Redo steps 7 and 8 |
| Run log shows a `MessageId` but no email arrived | The email was delivered but filtered | Check Spam/Bulk for no-reply@sns.amazonaws.com |
| Failure email arrived at Gmail, not Yahoo | That was GitHub's own notification, not SNS | Expected. SNS emails go to Yahoo (see 2.4). |
| Can't merge your own PR | Required approvals is 1 and you're working alone | Step 9: set required approvals to 0 for now |

---

## Next things to do

- **Staging before production** — deploy to a staging area first, then promote the same image to production with an approval
- **AWS Load Balancer Controller + Ingress** — a modern load balancer with HTTPS and path-based routing
- **Pod Identity / IRSA** — let the app call other AWS services (S3, DynamoDB) with its own limited permissions
- **Horizontal Pod Autoscaler** — add or remove copies automatically as traffic changes
