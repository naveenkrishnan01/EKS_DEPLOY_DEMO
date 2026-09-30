# eks_deploy_sample — Spring Boot on Amazon EKS

A minimal Spring Boot service deployed to **Amazon EKS** (Elastic Kubernetes Service), end to end:

1. Build a Spring Boot app with a `/Hello from EKS -` endpoint and health probes
2. Package it as a Docker image
3. Push the image to **Amazon ECR** (Elastic Container Registry)
4. Create an EKS cluster with `eksctl`
5. Deploy the app behind an AWS load balancer and test it
6. Ship a **v2** with a zero-downtime rolling update, and roll back if needed
7. Tear everything down

```
 Mac (build)              AWS (us-west-1)
 ┌──────────────┐  push   ┌───────────────────┐  pull   ┌──────────────────── EKS cluster ─────────────────────┐
 │ mvn + docker │ ──────▶ │        ECR        │ ──────▶ │  Deployment: eks-deploy-sample (2 pods)              │
 └──────────────┘         │ eks-deploy-sample │         │            ▲                                         │
                          └───────────────────┘         │  Service: eks-deploy-sample-svc (LoadBalancer :80)   │
                                                        └────────────┼─────────────────────────────────────────┘
                                                     curl http://<elb-hostname>/hello
```

---

## Contents

- [Prerequisites](#prerequisites)
- [Project structure](#project-structure)
- [Quick start (scripts)](#quick-start-scripts)
- [Step 1 — AWS credentials (IAM user, not root)](#step-1--aws-credentials-iam-user-not-root)
- [Step 2 — The Spring Boot app](#step-2--the-spring-boot-app)
- [Step 3 — Containerize with Docker](#step-3--containerize-with-docker)
- [Step 4 — Push the image to ECR](#step-4--push-the-image-to-ecr)
- [Step 5 — Create the EKS cluster](#step-5--create-the-eks-cluster)
- [Step 6 — Deploy to Kubernetes](#step-6--deploy-to-kubernetes)
- [Step 7 — Test v1](#step-7--test-v1)
- [Step 8 — Roll out v2](#step-8--roll-out-v2)
- [Step 9 — Clean up](#step-9--clean-up)
- [Troubleshooting (issues we actually hit)](#troubleshooting-issues-we-actually-hit)
- [Next things to do](#next-things-to-do)

---

## Prerequisites

| Tool | Install (macOS) | Check |
|---|---|---|
| Java 21 + Maven | `brew install openjdk@21 maven` | `java -version && mvn -v` |
| Docker Desktop | [docker.com](https://www.docker.com/products/docker-desktop/) | `docker info` |
| AWS CLI v2 | `brew install awscli` | `aws --version` |
| eksctl | `brew tap eksctl-io/eksctl && brew install eksctl-io/eksctl/eksctl` | `eksctl version` |
| kubectl | `brew install kubectl` | `kubectl version --client` |

> Use a **release** build of eksctl (plain version number), not a `-dev` build.

---

## Project structure

```
eks_deploy_sample/
├── Dockerfile
├── scripts/
│   ├── run-local.sh              # Build jar + image and run the container locally
│   ├── env.sh                    # Shared variables for Steps 4–9 (source ./scripts/env.sh)
│   ├── push-to-ecr.sh            # Build a linux/amd64 image and push it to ECR
│   ├── create-cluster.sh         # Create the EKS cluster and point kubectl at it
│   ├── deploy.sh                 # Apply k8s/app.yaml with the ECR image filled in
│   ├── test-app.sh               # Get the load balancer address and call /hello
│   ├── clean-up.sh               # Delete the app and the cluster
│   └── shut-down-docker.sh       # Stop containers and quit Docker Desktop
├── pom.xml
├── k8s/
│   └── app.yaml                  # Deployment + LoadBalancer Service
└── src/main/
    ├── java/com/example/eksdeploysample/
    │   └── EksDeploySampleApplication.java # /hello endpoint
    └── resources/
        └── application.yml
```

---

## Quick start (scripts)

After Step 1 (AWS credentials) and with Docker Desktop running, the whole flow is one script per step. Run everything from the project folder:

```bash
chmod +x scripts/*.sh                  # first time only

./scripts/run-local.sh                 # Step 3: build and run the container locally (Ctrl+C to stop)
source ./scripts/env.sh                # Step 4: load shared variables into this terminal
./scripts/push-to-ecr.sh v1            # Step 4: build and push the v1 image to ECR
./scripts/create-cluster.sh            # Step 5: create the EKS cluster (~15–20 min, starts billing)
./scripts/deploy.sh v1                 # Step 6: deploy v1 to the cluster
./scripts/test-app.sh                  # Step 7: get the load balancer address and call /hello

./scripts/push-to-ecr.sh v2            # Step 8: after changing the code, push v2 ...
./scripts/deploy.sh v2                 #         ... and roll it out

./scripts/clean-up.sh                  # Step 9: delete the app and the cluster when you're done
./scripts/shut-down-docker.sh          # Step 9: stop containers and quit Docker Desktop
```

| Script | Step | What it does |
|---|---|---|
| `scripts/run-local.sh` | 3 | Build the jar and image, run the container on `localhost:8080` in the foreground |
| `scripts/env.sh` | 4 | Set `AWS_REGION`, `ACCOUNT_ID`, `REPO`, `IMAGE_BASE` (use with `source`) |
| `scripts/push-to-ecr.sh <tag>` | 4, 8 | Create the ECR repo if needed, log in, build a `linux/amd64` image, push it |
| `scripts/create-cluster.sh` | 5 | Create `eks-sample-cluster` (skips if it exists) and point `kubectl` at it |
| `scripts/deploy.sh <tag>` | 6, 8 | Apply `k8s/app.yaml` with that image tag and wait for the rollout |
| `scripts/test-app.sh` | 7 | Get the load balancer address and call `/hello` |
| `scripts/clean-up.sh` | 9 | Delete the app and the cluster, then list anything still billing |
| `scripts/shut-down-docker.sh` | 9 | Stop running containers and quit Docker Desktop |

---

## Step 1 — AWS credentials (IAM user, not root)

Never use root account access keys. Create a dedicated admin IAM user instead.

**In the AWS Console (signed in as root, one last time):**

1. **IAM → Users → Create user** → name it `naveen-admin`.
2. **Attach policies directly** → select **AdministratorAccess** → **Create user**.
3. Open the user → **Security credentials** → **Create access key** → use case **CLI** → **download the .csv** (the secret is shown only once).
4. Turn on **MFA for the root user** (account menu → Security credentials), then sign out of root for good.

**On your Machine(laptop):**

```bash
aws configure
#   Access Key ID:      <from the csv>
#   Secret Access Key:  <from the csv>
#   Default region:     us-west-1
#   Output format:      json

aws sts get-caller-identity   # ARN should end in user/naveen-admin, not root
```

---

## Step 2 — The Spring Boot app

**`pom.xml`** — Spring Boot 3.5, Java 21, with `web` and `actuator`:

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.6</version>
</parent>

<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
</dependencies>
```

**`EksDeploySampleApplication.java`** — returns a message, a version, and the pod's hostname, so you can see which replica answered:

```java
@SpringBootApplication
@RestController
public class EksDeploySampleApplication {

    public static void main(String[] args) {
        SpringApplication.run(EksDeploySampleApplication.class, args);
    }

    @GetMapping("/hello")
    public Map<String, String> hello() throws Exception {
        return Map.of(
                "message", "Hello from EKS",
                "version", "v1",
                "pod", InetAddress.getLocalHost().getHostName());
    }
}
```

**`application.yml`** — turns on separate liveness/readiness endpoints for Kubernetes:

```yaml
spring:
  application:
    name: eks_deploy_sample                   # App name used in logs and actuator info
server:
  port: 8080                          # HTTP port (matches containerPort in k8s/app.yaml)
  shutdown: graceful                  # Finish in-flight requests before shutting down on pod termination
management:
  endpoint:
    health:
      probes:
        enabled: true                 # Separate liveness/readiness endpoints for Kubernetes probes
  endpoints:
    web:
      exposure:
        include: health,info          # Expose only health and info actuator endpoints over HTTP
```

**Build and run locally:**

```bash
mvn clean package -DskipTests
java -jar target/eks_deploy_sample.jar

# in another terminal
curl localhost:8080/hello
curl localhost:8080/actuator/health/readiness
```

---

## Step 3 — Containerize with Docker

**`Dockerfile`** (capital **D** — Linux CI is case-sensitive):

```dockerfile
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Make sure Docker Desktop is running (`docker info` must show a healthy **Server** section).

**Build and run the container locally with one command** — `scripts/run-local.sh` builds the jar, builds the image, and runs the container in the foreground:

```bash
#!/usr/bin/env bash
# Build the jar, build the Docker image, and run the container in the foreground.
# Usage: ./scripts/run-local.sh    (Ctrl+C to stop)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

IMAGE="eks-deploy-sample:local"          # Docker image name:tag to build and run
PORT="${PORT:-8080}"                     # Host port; defaults to 8080, override with PORT=9090 ./scripts/run-local.sh

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so pom.xml and Dockerfile are found

echo "==> Building jar"                  # Progress message
mvn clean package -DskipTests            # Delete old target/ and build a fresh jar, skipping tests

echo "==> Building image $IMAGE"         # Progress message
docker build -t "$IMAGE" .               # Build the image from the Dockerfile in this folder

echo "==> Running $IMAGE on http://localhost:$PORT (Ctrl+C to stop)"  # Progress message
exec docker run --rm -it -p "$PORT:8080" "$IMAGE"  # Run in foreground; --rm removes container on exit, -it attaches terminal, -p maps host port to container 8080
```

Run it (Docker Desktop must be running, and nothing else can be using port 8080, such as the `java -jar` run from Step 2):

```bash
chmod +x scripts/run-local.sh      # first time only
./scripts/run-local.sh             # or: PORT=9090 ./scripts/run-local.sh

# in another terminal
curl localhost:8080/hello
curl localhost:8080/actuator/health/readiness
```

Press `Ctrl+C` to stop; the container is removed automatically.

> This local image is built for your Mac's CPU. The image pushed to EKS in Step 4 is built separately with `--platform linux/amd64`.

---

## Step 4 — Push the image to ECR

Steps 4–9 use a few shared variables. They live in **`scripts/env.sh`**:

```bash
# Shared settings for Steps 4–9. Load into the current terminal with: source ./scripts/env.sh
# (must be sourced, not run as ./scripts/env.sh — a script can't set variables in your terminal)
export AWS_REGION=us-west-1              # AWS region for ECR and EKS
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
export REPO=eks-deploy-sample            # ECR repository name
export IMAGE_BASE=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO           # Image address without the tag

echo "AWS_REGION=$AWS_REGION"            # Show the values so you can see they loaded
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "REPO=$REPO"
echo "IMAGE_BASE=$IMAGE_BASE"
```

Load them into your terminal:

```bash
source ./scripts/env.sh     # IMAGE_BASE must NOT be blank
```

> **Variables only last for the current terminal tab.** In a new tab or window, or after a restart, run `source ./scripts/env.sh` again from the project folder before any later step. Otherwise commands like `--region $AWS_REGION` receive nothing and fail. (The Docker login to ECR is different: it's saved to disk and lasts about 12 hours.)

**Build and push with one command.** `scripts/push-to-ecr.sh` creates the ECR repository if it doesn't exist yet, logs Docker in to ECR, builds the jar, builds a `linux/amd64` image, pushes it, and lists the tags in the repository:

```bash
#!/usr/bin/env bash
# Build the jar, build a linux/amd64 image, and push it to Amazon ECR.
# Usage: ./scripts/push-to-ecr.sh <tag>    (e.g. ./scripts/push-to-ecr.sh v1, ./scripts/push-to-ecr.sh v2, ./scripts/push-to-ecr.sh v3)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

TAG="${1:?Usage: ./scripts/push-to-ecr.sh <tag>  (e.g. ./scripts/push-to-ecr.sh v1)}"  # Image tag from the first argument (required); stops with the usage message if missing
AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/push-to-ecr.sh
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"                 # ECR registry host for this account and region
IMAGE="$REGISTRY/$REPO:$TAG"             # Full image address to build and push

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so pom.xml and Dockerfile are found

echo "==> Ensuring ECR repository $REPO exists"  # Progress message
aws ecr describe-repositories --repository-names "$REPO" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" >/dev/null  # Create the repo only if it's missing

echo "==> Logging Docker in to $REGISTRY"        # Progress message
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"  # Pipe a temporary ECR password into docker login

echo "==> Building jar"                  # Progress message
mvn clean package -DskipTests            # Delete old target/ and build a fresh jar, skipping tests

echo "==> Building image $IMAGE"         # Progress message
docker build --platform linux/amd64 -t "$IMAGE" .  # Build for x86 so it runs on the EKS nodes (even from an Apple Silicon Mac)

echo "==> Pushing $IMAGE"                # Progress message
docker push "$IMAGE"                     # Upload the image to ECR

echo "==> Tags now in $REPO:"            # Progress message
aws ecr list-images --repository-name "$REPO" --region "$AWS_REGION" \
  --query 'imageIds[].imageTag' --output text  # List the tags in the repo to confirm the push
```

Run it:

```bash
chmod +x scripts/push-to-ecr.sh    # first time only
./scripts/push-to-ecr.sh v1        # build and push $IMAGE_BASE:v1
```

The tag is required: pass `v1` now, and `v2`, `v3`, … for later releases (Step 8). Running it without a tag stops with a usage message. The last lines of output list the tags in ECR and should include `v1`.

<details>
<summary>The same steps run by hand</summary>

```bash
aws ecr create-repository --repository-name $REPO --region $AWS_REGION

aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
# → Login Succeeded

mvn clean package -DskipTests
docker build --platform linux/amd64 -t $IMAGE_BASE:v1 .
docker push $IMAGE_BASE:v1

aws ecr list-images --repository-name $REPO --region $AWS_REGION   # should list v1
```

</details>

> `--platform linux/amd64` matters on Apple Silicon Macs: the EKS nodes are x86, and an ARM image fails with `exec format error`.

---

## Step 5 — Create the EKS cluster

> **New terminal?** Run `source ./scripts/env.sh` first (see Step 4).

**Pick an instance type your account allows.** New AWS accounts on the **Free plan** can only launch free-tier-eligible instance types. List them:

```bash
aws ec2 describe-instance-types --region $AWS_REGION \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
  --output table
```

Choose the largest x86 option (for example `m7i-flex.large` or `c7i-flex.large`). Accounts on the Paid plan can use `t3.medium`.

**Create the cluster with one command** (~15–20 minutes). `scripts/create-cluster.sh` skips creation if the cluster already exists, runs `eksctl create cluster`, points `kubectl` at the cluster, and lists the nodes:

```bash
#!/usr/bin/env bash
# Create the EKS cluster and managed node group with eksctl, then point kubectl at it (~15–20 min).
# Usage: ./scripts/create-cluster.sh    (override with e.g. NODE_TYPE=c7i-flex.large ./scripts/create-cluster.sh)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/create-cluster.sh
CLUSTER="${CLUSTER:-eks-sample-cluster}" # EKS cluster name
NODEGROUP="${NODEGROUP:-eks-nodes}"     # Managed node group name
NODE_TYPE="${NODE_TYPE:-m7i-flex.large}" # EC2 instance type for worker nodes (must be free-tier eligible on the Free plan)
NODES="${NODES:-2}"                      # Number of worker nodes to start with

if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then  # Skip creation if the cluster already exists
  echo "==> Cluster $CLUSTER already exists in $AWS_REGION, skipping create"                 # Progress message
else
  echo "==> Creating cluster $CLUSTER in $AWS_REGION with $NODES x $NODE_TYPE (~15–20 min)"  # Progress message
  eksctl create cluster \
    --name "$CLUSTER" \
    --region "$AWS_REGION" \
    --nodegroup-name "$NODEGROUP" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODES" --nodes-min 1 --nodes-max 3 \
    --managed                            # Build VPC, control plane, and a managed node group via CloudFormation
fi

echo "==> Pointing kubectl at $CLUSTER"  # Progress message
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"  # Write/refresh the cluster entry in ~/.kube/config

echo "==> Nodes:"                        # Progress message
kubectl get nodes                        # Should list the worker nodes with STATUS Ready
```

Run it, passing the instance type you chose above:

```bash
chmod +x scripts/create-cluster.sh                         # first time only
./scripts/create-cluster.sh       # run the script
```

<details>
<summary>The same command run by hand</summary>

```bash
eksctl create cluster \
  --name eks-sample-cluster \
  --region $AWS_REGION \
  --nodegroup-name demo-nodes \
  --node-type m7i-flex.large \
  --nodes 2 --nodes-min 1 --nodes-max 3 \
  --managed
```

</details>

What this builds, via CloudFormation:
- A VPC with public and private subnets
- The EKS control plane (the Kubernetes API)
- A managed node group of 2 EC2 worker nodes
- Core add-ons: `vpc-cni`, `coredns`, `kube-proxy`
- An entry in `~/.kube/config` so `kubectl` points at the new cluster

> The yellow `[!]` warning about **OIDC** and `vpc-cni` is safe to ignore.

**Verify:** the script ends with `kubectl get nodes`, which should show 2 nodes with STATUS `Ready`. To check again later:

```bash
kubectl get nodes
```

If `kubectl` can't reach the cluster, run `./scripts/create-cluster.sh` again. It skips creation and just refreshes `~/.kube/config`. Or run the command directly:
```bash
aws eks update-kubeconfig --name eks-sample-cluster --region $AWS_REGION
```

---

## Step 6 — Deploy to Kubernetes

> **New terminal?** Run `source ./scripts/env.sh` first (see Step 4).

**`k8s/app.yaml`:**

```yaml
apiVersion: apps/v1                     # API group/version for Deployments
kind: Deployment                        # Manages a replicated set of pods
metadata:                               # Deployment identity
  name: eks-deploy-sample                       # Deployment name
spec:                                   # Desired state
  replicas: 2                           # Run two pods
  selector:                             # How the Deployment finds its pods
    matchLabels: { app: eks-deploy-sample }     # Match pods labeled app=eks-deploy-sample
  template:                             # Pod template
    metadata:                           # Pod metadata
      labels: { app: eks-deploy-sample }        # Label that the selector matches
    spec:                               # Pod spec
      containers:                       # Containers in the pod
        - name: eks-deploy-sample               # Container name
          image: IMAGE_URI              # Placeholder replaced with the ECR image at deploy time
          ports: [{ containerPort: 8080 }]  # Spring Boot listens on 8080
          resources:                    # CPU/memory sizing
            requests: { cpu: "250m", memory: "512Mi" }  # Guaranteed minimum for scheduling
            limits:   { memory: "768Mi" }  # Memory cap on pod
          readinessProbe:               # Gate traffic until app is ready
            httpGet: { path: /actuator/health/readiness, port: 8080 }  # Actuator readiness endpoint
            initialDelaySeconds: 20     # Wait 20s before first check
          livenessProbe:                # Restart container if unhealthy
            httpGet: { path: /actuator/health/liveness, port: 8080 }  # Actuator liveness endpoint
            initialDelaySeconds: 40     # Wait 40s before first check
---
apiVersion: v1                          # Core API version for Services
kind: Service                           # Stable network endpoint for the pods
metadata:                               # Service identity
  name: eks-deploy-sample-svc                   # Service name
spec:                                   # Desired state
  type: LoadBalancer                    # Provision an AWS load balancer
  selector: { app: eks-deploy-sample }          # Route to pods labeled app=eks-deploy-sample
  ports: [{ port: 80, targetPort: 8080 }]  # Expose port 80, forward to container 8080
```

What each part does:

| Piece | Purpose |
|---|---|
| `Deployment` | Keeps 2 replicas of the app running and handles rolling updates |
| `image: IMAGE_URI` | Placeholder, filled in at deploy time with the real ECR address |
| `resources` | Reserves CPU/memory so the scheduler places pods on nodes with room |
| `readinessProbe` | A pod receives traffic only after `/actuator/health/readiness` returns UP |
| `livenessProbe` | Kubernetes restarts the container if `/actuator/health/liveness` fails |
| `Service` (`LoadBalancer`) | AWS creates a public load balancer: port 80 → pod port 8080 |

> Kubernetes resource and container names can't contain underscores, so the manifest uses `eks-deploy-sample` even though the project is `eks_deploy_sample`.

**Deploy with one command.** You don't paste the manifest into the terminal. `scripts/deploy.sh` reads `k8s/app.yaml`, replaces `IMAGE_URI` with the ECR image address, applies it, waits for the rollout, and shows the pods and the Service:

```bash
#!/usr/bin/env bash
# Deploy k8s/app.yaml to the cluster with the ECR image filled in, and wait for the rollout.
# Usage: ./scripts/deploy.sh <tag>    (e.g. ./scripts/deploy.sh v1, ./scripts/deploy.sh v2, ./scripts/deploy.sh v3)
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

TAG="${1:?Usage: ./scripts/deploy.sh <tag>  (e.g. ./scripts/deploy.sh v1)}"  # Image tag from the first argument (required); stops with the usage message if missing
AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/deploy.sh
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)  # AWS account ID of the current credentials
IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO:$TAG"          # Full image address to deploy

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so k8s/app.yaml is found

echo "==> Deploying $IMAGE"              # Progress message
sed "s|IMAGE_URI|$IMAGE|" k8s/app.yaml | kubectl apply -f -  # Replace the IMAGE_URI placeholder and apply the manifest

echo "==> Waiting for rollout"           # Progress message
kubectl rollout status deployment/eks-deploy-sample --timeout=5m  # Block until all pods are updated and ready (fail after 5 min)

echo "==> Pods:"                         # Progress message
kubectl get pods -l app=eks-deploy-sample  # Should show 2 pods at 1/1 Running

echo "==> Service:"                      # Progress message
kubectl get svc eks-deploy-sample-svc    # EXTERNAL-IP is the load balancer hostname (may show <pending> for a minute)
```

Run it:

```bash
chmod +x scripts/deploy.sh     # first time only
./scripts/deploy.sh v1         # deploy $IMAGE_BASE:v1
```

The tag is required and must already be in ECR (pushed with `./scripts/push-to-ecr.sh <tag>`).

Both pods should reach `1/1 Running` within about 1–2 minutes. The Service's `EXTERNAL-IP` may show `<pending>` for a minute while AWS creates the load balancer.

<details>
<summary>The same steps run by hand</summary>

```bash
sed "s|IMAGE_URI|$IMAGE_BASE:v1|" k8s/app.yaml | kubectl apply -f -
kubectl rollout status deployment/eks-deploy-sample
kubectl get pods
```

</details>

---

## Step 7 — Test v1

**Test with one command.** `scripts/test-app.sh` gets the load balancer address and calls `/hello`:

```bash
#!/usr/bin/env bash
# Get the load balancer address and call /hello.
# Usage: ./scripts/test-app.sh
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

URL=$(kubectl get svc eks-deploy-sample-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')  # Load balancer hostname of the Service
echo $URL                                # Show the address
curl http://$URL/hello                   # Call the /hello endpoint
echo                                     # Newline after the JSON response
```

Run it:

```bash
chmod +x scripts/test-app.sh   # first time only
./scripts/test-app.sh
```

<details>
<summary>The same steps run by hand</summary>

```bash
export URL=$(kubectl get svc eks-deploy-sample-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $URL
curl http://$URL/hello
```

</details>

Expected response:

```json
{"message":"Hello from EKS","version":"v1","pod":"eks-deploy-sample-cc445fbd6-4pzg7"}
```

- The first run can fail for 2–3 minutes while the load balancer's DNS name starts resolving. Wait and run it again.
- Run it several times: the `pod` value alternates between the two replicas, which shows the load balancer spreading traffic.

**Where to see it in the AWS console** (region **us-west-1**):
- **The Service:** EKS → Clusters → `eks-sample-cluster` → **Resources** → Service and networking → Services → `eks-deploy-sample-svc`. You must be signed in as the IAM user that created the cluster (`naveen-admin`), not root.
- **The load balancer it created:** EC2 → Load Balancers. It has a generated name. Match its **DNS name** to `$URL`, or look for the tag `kubernetes.io/service-name = default/eks-deploy-sample-svc`.

---

## Step 8 — Roll out v2

> **New terminal?** Run `source ./scripts/env.sh` first (see Step 4).

**1. Change the code** in `EksDeploySampleApplication.java`:

```java
"message", "Hello from EKS - updated!",
"version", "v2",
```

**2. Build and push under a new tag:**

```bash
./scripts/push-to-ecr.sh v2
```

**3. Point the Deployment at v2:**

```bash
./scripts/deploy.sh v2
```

For later releases, repeat with `v3`, `v4`, … .

**4. Watch the switch live.** In a second terminal, start this *before* step 3 (Ctrl+C to stop):

```bash
export URL=$(kubectl get svc eks-deploy-sample-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $URL    # must NOT be blank
while true; do curl -s http://$URL/hello; echo; sleep 1; done
```

Responses flip from `v1` to `v2` with no failed requests. This is a **rolling update**: Kubernetes starts a v2 pod, waits for its readiness probe to pass, sends it traffic, and only then retires a v1 pod, one at a time.

Or, once the rollout finishes, run `./scripts/test-app.sh` and check that the response says `v2`.

**Roll back** if v2 misbehaves:

```bash
kubectl rollout undo deployment/eks-deploy-sample
kubectl rollout history deployment/eks-deploy-sample
```

> Always push a **new tag** for each release (`v1`, `v2`, …). Reusing a tag makes rollouts and rollbacks unreliable.

---

## Step 9 — Clean up

> **New terminal?** Run `source ./scripts/env.sh` first (see Step 4).

EKS bills for the control plane (~$0.10/hour) plus the EC2 nodes and the load balancer. Delete everything when you're done.

**Clean up with one command.** `scripts/clean-up.sh` deletes the app first (so the load balancer is removed cleanly), then the cluster, and finally lists any clusters or load balancers still in the region:

```bash
#!/usr/bin/env bash
# Delete the app, the load balancer, and the EKS cluster, then check nothing is left billing.
# Usage: ./scripts/clean-up.sh
set -euo pipefail                        # Exit on error, on unset variables, and on failures inside pipes

AWS_REGION="${AWS_REGION:-us-west-1}"    # AWS region; override with AWS_REGION=... ./scripts/clean-up.sh
CLUSTER="${CLUSTER:-eks-sample-cluster}" # EKS cluster name
REPO="${REPO:-eks-deploy-sample}"        # ECR repository name

cd "$(dirname "$0")/.."                  # Move to the project root (parent of scripts/) so k8s/app.yaml is found

echo "==> Deleting the app and its load balancer"  # Progress message
kubectl delete -f k8s/app.yaml --ignore-not-found  # Remove the Deployment and Service first, so AWS deletes the load balancer cleanly

echo "==> Deleting cluster $CLUSTER (~10–15 min)"  # Progress message
eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION" --wait  # Delete the cluster, node group, and VPC

# Optional: also delete the ECR repository and all its images (uncomment to use)
# aws ecr delete-repository --repository-name "$REPO" --force --region "$AWS_REGION"

echo "==> Remaining clusters (should be empty):"  # Progress message
aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text  # Any EKS clusters still in the region

echo "==> Remaining load balancers (should be empty):"  # Progress message
aws elb describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text  # Classic load balancers
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerName' --output text          # Application/network load balancers
```

Run it:

```bash
chmod +x scripts/clean-up.sh   # first time only
./scripts/clean-up.sh
```

The "Remaining" sections at the end should print nothing. The ECR repository and its images are kept, since storing them costs very little. To delete them too, uncomment the `aws ecr delete-repository` line in the script, or run it by hand.

<details>
<summary>The same steps run by hand</summary>

```bash
# 1. Remove the app first, so the load balancer is deleted cleanly
kubectl delete -f k8s/app.yaml

# 2. Delete the cluster, node group and VPC (~10–15 min)
eksctl delete cluster --name eks-sample-cluster --region $AWS_REGION --wait

# 3. Optional: delete the image repository
aws ecr delete-repository --repository-name $REPO --force --region $AWS_REGION

# Confirm nothing is left billing
aws eks list-clusters --region $AWS_REGION                         # "clusters": []
aws elb   describe-load-balancers --region $AWS_REGION --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws elbv2 describe-load-balancers --region $AWS_REGION --query 'LoadBalancers[].LoadBalancerName'
```

</details>

**Shut down Docker** when you no longer need it. `scripts/shut-down-docker.sh` stops any running containers and quits Docker Desktop:

```bash
#!/usr/bin/env bash
# Stop all running containers and quit Docker Desktop.
# Usage: ./scripts/shut-down-docker.sh

docker stop $(docker ps -q)              # Stop every running container (e.g. the one from run-local.sh)
osascript -e 'quit app "Docker"'         # Quit Docker Desktop, which also stops the Docker engine
```

Run it:

```bash
chmod +x scripts/shut-down-docker.sh   # first time only
./scripts/shut-down-docker.sh
```

Optionally, reclaim disk space from old images first with `docker system prune -a`.

---

## Troubleshooting (issues we actually hit)

### `SignatureDoesNotMatch` on `aws sts get-caller-identity`
The secret key in `~/.aws/credentials` doesn't match the access key ID.
- Check for overriding variables: `env | grep AWS` (clear them with `unset`).
- Inspect the file for stray characters: `cat -e ~/.aws/credentials`. The `$` at each line end is just `cat -e` marking the line end; `^M` or a space before `$` is a problem.
- Most reliable fix: create a new access key for the IAM user and run `aws configure` again.

### Docker: `500 Internal Server Error ... docker.sock`
The Docker **engine** isn't healthy (`docker info` shows the client, but the Server section errors).
```bash
osascript -e 'quit app "Docker"'; sleep 5; open -a Docker
```
Wait for "Docker Desktop is running". If it persists, use Troubleshoot → Restart in Docker Desktop, restart the Mac, or update Docker Desktop.

### `bind: address already in use` from `run-local.sh`
Something else on your Mac is using port 8080, usually the `java -jar` app from Step 2 that's still running. Find it:
```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```
Stop it (Ctrl+C in its terminal, or `kill <PID>` using the PID shown), or run the container on another port: `PORT=9090 ./scripts/run-local.sh`.

### `zsh: parse error near '\n'`
A command was pasted with a `<...>` placeholder still in it. zsh reads `<` and `>` as redirection. Replace the whole placeholder, brackets included, with the real value.

### `zsh: bad substitution` or odd `!` behavior
Some bash-only syntax, such as `${!v}`, doesn't work in zsh, and zsh expands `!` in pasted commands from your history. Use the zsh form or run the command with `bash -c '...'`.

### EKS node group stuck in `CREATING`, then eksctl times out
Symptoms: `describe-nodegroup` shows `CREATING` with no health issues and no EC2 instances launch.
**Find the real error in CloudTrail**, which keeps 90 days of API history even after the cluster is deleted:

```bash
aws cloudtrail lookup-events --region us-west-1 \
  --start-time <UTC start> --end-time <UTC end> --output json | python3 -c '
import json, sys
for e in json.load(sys.stdin)["Events"]:
    d = json.loads(e["CloudTrailEvent"])
    if "errorCode" in d:
        print(d["eventTime"], d["eventSource"], d["eventName"], d["errorCode"], d.get("errorMessage", "")[:200])'
```

Replace `<UTC start>` and `<UTC end>` with real times, for example `2026-09-30T18:00:00Z`. Pasting the `<...>` text as-is causes a shell parse error.

Our root cause: `RunInstances → "The specified instance type is not eligible for Free Tier."` The account was on the **Free plan** and `t3.medium` isn't eligible. **Fix:** use a free-tier-eligible type (Step 5) or upgrade the account to the Paid plan.

> An `aws ec2 run-instances --dry-run` test does **not** catch this restriction, so it can report "would have succeeded" even though real launches are refused.

### `aws: error: argument --region: expected one argument`
`$AWS_REGION` is empty because this terminal doesn't have the Step 4 variables. Run `source ./scripts/env.sh` from the project folder and try again.

### Pods show `InvalidImageName`
The image address was blank because `$IMAGE_BASE` wasn't set in the current terminal. Check it:
```bash
kubectl get deployment eks-deploy-sample -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```
Run `./scripts/deploy.sh` again, which works out the image address itself.

### Pods show `ErrImagePull` / `ImagePullBackOff`
The address is valid, but the tag isn't in ECR. Confirm with `aws ecr list-images --repository-name eks-deploy-sample`, push the missing tag, then force an immediate retry:
```bash
kubectl delete pod <pod-name>
```

### Handy diagnostics
```bash
kubectl get pods -w                             # live pod status
kubectl describe pod <name> | tail -20          # Events explain pull / scheduling errors
kubectl logs <name>                             # Spring Boot startup output
kubectl get events --sort-by=.lastTimestamp     # cluster-wide recent events
```

---

## Next things to do

- **AWS Load Balancer Controller + Ingress** — an ALB with path-based routing and HTTPS
- **CI/CD** — a GitHub Actions workflow that builds, pushes and deploys on every commit
- **Pod Identity / IRSA** — give pods scoped IAM permissions to call S3, DynamoDB, etc.
- **Horizontal Pod Autoscaler** — scale replicas automatically on CPU load
