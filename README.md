# eks_deploy_sample — Spring Boot on Amazon EKS

A minimal Spring Boot service deployed to **Amazon EKS** (Elastic Kubernetes Service), end to end:

1. Build a Spring Boot app with a `/hello` endpoint and health probes
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

## Step 1 — AWS credentials (IAM user, not root)

Never use root account access keys. Create a dedicated admin IAM user instead.

**In the AWS Console (signed in as root, one last time):**

1. **IAM → Users → Create user** → name it `naveen-admin`.
2. **Attach policies directly** → select **AdministratorAccess** → **Create user**.
3. Open the user → **Security credentials** → **Create access key** → use case **CLI** → **download the .csv** (the secret is shown only once).
4. Turn on **MFA for the root user** (account menu → Security credentials), then sign out of root for good.

**On your Mac:**

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

---

## Step 4 — Push the image to ECR

Set these once per terminal session. Every later command uses them:

```bash
export AWS_REGION=us-west-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REPO=eks-deploy-sample
export IMAGE_BASE=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO
echo $IMAGE_BASE    # must NOT be blank
```

Create the repository, log Docker in to ECR, then build and push:

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

> `--platform linux/amd64` matters on Apple Silicon Macs: the EKS nodes are x86, and an ARM image fails with `exec format error`.

---

## Step 5 — Create the EKS cluster

**Pick an instance type your account allows.** New AWS accounts on the **Free plan** can only launch free-tier-eligible instance types. List them:

```bash
aws ec2 describe-instance-types --region $AWS_REGION \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
  --output table
```

Choose the largest x86 option (for example `m7i-flex.large` or `c7i-flex.large`). Accounts on the Paid plan can use `t3.medium`.

**Create the cluster** (~15–20 minutes):

```bash
eksctl create cluster \
  --name demo-cluster \
  --region $AWS_REGION \
  --nodegroup-name demo-nodes \
  --node-type m7i-flex.large \
  --nodes 2 --nodes-min 1 --nodes-max 3 \
  --managed
```

What this builds, via CloudFormation:
- A VPC with public and private subnets
- The EKS control plane (the Kubernetes API)
- A managed node group of 2 EC2 worker nodes
- Core add-ons: `vpc-cni`, `coredns`, `kube-proxy`
- An entry in `~/.kube/config` so `kubectl` points at the new cluster

> The yellow `[!]` warning about **OIDC** and `vpc-cni` is safe to ignore for this demo.

**Verify:**

```bash
kubectl get nodes    # 2 nodes, STATUS Ready
```

If `kubectl` can't reach the cluster:
```bash
aws eks update-kubeconfig --name demo-cluster --region $AWS_REGION
```

---

## Step 6 — Deploy to Kubernetes

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

**Deploy**, substituting the image address:

```bash
sed "s|IMAGE_URI|$IMAGE_BASE:v1|" k8s/app.yaml | kubectl apply -f -
kubectl rollout status deployment/eks-deploy-sample
kubectl get pods
```

Both pods should reach `1/1 Running` within about 1–2 minutes.

---

## Step 7 — Test v1

```bash
export URL=$(kubectl get svc eks-deploy-sample-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $URL
curl http://$URL/hello
```

Expected response:

```json
{"message":"Hello from EKS","version":"v1","pod":"eks-deploy-sample-cc445fbd6-4pzg7"}
```

- The first `curl` can fail for 2–3 minutes while the load balancer's DNS name starts resolving.
- Run it several times: the `pod` value alternates between the two replicas, which shows the load balancer spreading traffic.

---

## Step 8 — Roll out v2

**1. Change the code** in `EksDeploySampleApplication.java`:

```java
"message", "Hello from EKS - updated!",
"version", "v2",
```

**2. Build and push under a new tag:**

```bash
mvn clean package -DskipTests
docker build --platform linux/amd64 -t $IMAGE_BASE:v2 .
docker push $IMAGE_BASE:v2
```

**3. Point the Deployment at v2:**

```bash
kubectl set image deployment/eks-deploy-sample eks-deploy-sample=$IMAGE_BASE:v2
kubectl rollout status deployment/eks-deploy-sample
```

**4. Watch the switch live.** In a second terminal (set `URL` there too), start this *before* step 3:

```bash
while true; do curl -s http://$URL/hello; echo; sleep 1; done
```

Responses flip from `v1` to `v2` with no failed requests. This is a **rolling update**: Kubernetes starts a v2 pod, waits for its readiness probe to pass, sends it traffic, and only then retires a v1 pod, one at a time.

**Roll back** if v2 misbehaves:

```bash
kubectl rollout undo deployment/eks-deploy-sample
kubectl rollout history deployment/eks-deploy-sample
```

> Always push a **new tag** for each release (`v1`, `v2`, …). Reusing a tag makes rollouts and rollbacks unreliable.

---

## Step 9 — Clean up

EKS bills for the control plane (~$0.10/hour) plus the EC2 nodes and the load balancer. Delete everything when you're done.

```bash
# 1. Remove the app first, so the load balancer is deleted cleanly
kubectl delete -f k8s/app.yaml

# 2. Delete the cluster, node group and VPC (~10–15 min)
eksctl delete cluster --name demo-cluster --region $AWS_REGION --wait

# 3. Optional: delete the image repository
aws ecr delete-repository --repository-name $REPO --force --region $AWS_REGION
```

**Confirm nothing is left billing:**

```bash
aws eks list-clusters --region $AWS_REGION                         # "clusters": []
aws elb   describe-load-balancers --region $AWS_REGION --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws elbv2 describe-load-balancers --region $AWS_REGION --query 'LoadBalancers[].LoadBalancerName'
```

**Stop Docker Desktop** when you no longer need it:

```bash
docker system prune -a          # optional: reclaim disk space from images
osascript -e 'quit app "Docker"'
```

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

Our root cause: `RunInstances → "The specified instance type is not eligible for Free Tier."` The account was on the **Free plan** and `t3.medium` isn't eligible. **Fix:** use a free-tier-eligible type (Step 5) or upgrade the account to the Paid plan.

> An `aws ec2 run-instances --dry-run` test does **not** catch this restriction, so it can report "would have succeeded" even though real launches are refused.

### Pods show `InvalidImageName`
The image address was blank because `$IMAGE_BASE` wasn't set in the current terminal. Check it:
```bash
kubectl get deployment eks-deploy-sample -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```
Re-export the variables (Step 4) and re-run the `sed ... | kubectl apply` command.

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
