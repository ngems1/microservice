# Run the shop locally

Two ways, both on Docker Desktop:

- **Part A, Docker Compose:** all 12 services plus local Redis, MySQL and DynamoDB. The plan's Day 1 deliverable.
- **Part B, Docker Desktop Kubernetes:** the same images deployed with the project's Helm chart, as on EKS. A rehearsal for the cluster.

# Part A: Docker Compose

Runs all 12 services on your laptop with local stand-ins for the AWS data services. This is the plan's Day 1 "run the stack locally with Docker Compose" deliverable.

| AWS (dev/prod) | Locally |
|---|---|
| ElastiCache Redis | `redis-cart` container |
| RDS MySQL | `mysql` container, loaded from `db/migrations` on first start |
| DynamoDB | `dynamodb` container (DynamoDB Local) + `dynamodb-init`, which creates the table |
| EventBridge, SQS, Lambda | Not run locally. The event flow is tested on AWS dev. |

## 1. One-time setup

1. Install **Docker Desktop for Windows** (docker.com/products/docker-desktop). Accept the WSL 2 setup it offers, then restart.
2. Docker Desktop > Settings > Resources: give it at least **6 GB memory** and 4 CPUs.
3. Check it works: open PowerShell and run `docker version`.

## 2. Start

In PowerShell:

```powershell
cd "C:\Users\Sebastien Ngembou\Downloads\project-3"
docker compose up --build -d
```

The first build takes **20 to 40 minutes**: 12 images in Go, C#, Java, Node.js and Python. Later starts take seconds.

Check that everything is running:

```powershell
docker compose ps
```

Every service should show `running`. `dynamodb-init` shows `exited (0)`, which is correct: it only creates the table.

## 3. Try it

| What | Where |
|---|---|
| The shop | http://localhost:8080 |
| Stock for all products | http://localhost:8081/stock |
| Stock for the Mug (starts at 2) | http://localhost:8081/stock/6E92ZMYYFZ |
| inventoryservice metrics | http://localhost:8081/metrics |
| MySQL (e.g. MySQL Workbench) | `127.0.0.1:3306`, user `boutique`, password `boutique-local`, database `boutique` |

Check that the database schema loaded:

```powershell
docker compose exec mysql mysql -uboutique -pboutique-local boutique -e "SHOW TABLES; SELECT id, name FROM products;"
```

Optional: simulate users browsing and buying:

```powershell
docker compose --profile load up -d
docker compose logs -f loadgenerator
```

## 4. Useful commands

| Command | What it does |
|---|---|
| `docker compose logs -f checkoutservice` | Follow one service's logs |
| `docker compose restart cartservice` | Restart one service |
| `docker compose up --build -d inventoryservice` | Rebuild one service after a code change |
| `docker compose stop cartservice` | Simulate a service failure (watch the shop's cart break, then `start` it again) |
| `docker compose down` | Stop everything (MySQL data kept) |
| `docker compose down -v` | Stop and wipe MySQL data (migrations re-run on next start) |

## Troubleshooting

| Problem | Fix |
|---|---|
| Build stops with "out of memory" or is very slow | Give Docker Desktop more memory (step 1.2), then `docker compose up --build -d` again |
| `port is already allocated` for 8080, 8081 or 3306 | Another program uses that port. Stop it, or change the left number in `docker-compose.yml` (e.g. `"9080:8080"`). |
| The shop shows an error right after start | Services are still starting. Wait 30 seconds and refresh. |
| `inventoryservice` keeps restarting | `docker compose logs inventoryservice`. Usually DynamoDB Local was not ready. Run `docker compose restart inventoryservice`. |
| A changed `db/migrations` file has no effect | Init scripts only run on an empty database. Run `docker compose down -v`, then `up` again. |

# Part B: Docker Desktop Kubernetes (Helm)

Deploys the shop to the single-node Kubernetes cluster built into Docker Desktop, using the same Helm chart as EKS. Good for practising `kubectl` and `helm` before the real cluster.

What differs from EKS: Redis runs as a pod instead of ElastiCache, the shop is published on `http://localhost` instead of an ALB, and **inventoryservice is off** because DynamoDB only exists in AWS (use Part A to try it locally).

## B1. One-time setup

1. Docker Desktop > Settings > **Kubernetes** > tick **Enable Kubernetes**. If asked for a cluster type, choose **kubeadm** (single node; it uses the images you build with Docker directly). Apply & restart, and wait until the Kubernetes icon is green.
2. Install Helm, then **close and reopen PowerShell**:

   ```powershell
   winget install Helm.Helm
   ```

3. Check both tools:

   ```powershell
   kubectl config use-context docker-desktop
   kubectl get nodes
   helm version
   ```

## B2. Build the images and deploy

```powershell
cd "C:\Users\Sebastien Ngembou\Downloads\project-3"
docker compose down                 # free memory if the Compose stack is running
docker compose build                # builds every image as boutique/<service>:local
helm install boutique ./helm-chart -n boutique-local --create-namespace -f helm-chart/values-local.yaml
kubectl get pods -n boutique-local -w   # wait until all pods are Running (Ctrl+C to stop watching)
```

Open the shop at **http://localhost**.

## B3. Things to practise

| Command | What it shows |
|---|---|
| `kubectl get pods,svc -n boutique-local` | Every pod and service |
| `kubectl logs -n boutique-local deploy/checkoutservice -f` | One service's logs |
| `kubectl delete pod -n boutique-local -l app=cartservice` | Pod failure: Kubernetes recreates it within seconds |
| `kubectl scale deploy/frontend -n boutique-local --replicas=2` | Scaling |
| `helm upgrade boutique ./helm-chart -n boutique-local -f helm-chart/values-local.yaml --set loadGenerator.create=true` | Change a setting with Helm (here: start the load generator) |
| `helm history boutique -n boutique-local` then `helm rollback boutique 1 -n boutique-local` | **Rollback**, as in the plan's Day 4/5 |
| `helm uninstall boutique -n boutique-local` | Remove everything |

After changing a service's code: `docker compose build <service>`, then `kubectl rollout restart deploy/<service> -n boutique-local`.

| Problem | Fix |
|---|---|
| Pods stuck in `Pending` | Not enough memory: give Docker Desktop more (8 GB), or keep `loadGenerator.create=false` |
| `ErrImagePull` / `ImagePullBackOff` | The image wasn't built, or the cluster type is kind instead of kubeadm. Run `docker compose build` and check B1 step 1. |
| http://localhost doesn't answer | `kubectl get svc frontend-external -n boutique-local` must show `localhost` under EXTERNAL-IP. Port 80 may be used by another program (e.g. IIS). |

Local runs are for quick checks only. Deployments to AWS go through GitHub Actions and do not need Docker on your laptop.
