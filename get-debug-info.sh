#!/bin/bash

set -e

# Output directories
SCRIPT_DIR=$(cd "$(dirname "$0")" || exit; pwd)
OUT_DIR="${SCRIPT_DIR}/che-debug-$(date -u +%y%m%d%H%M%S)/"
DWO_DIR="$OUT_DIR/operators/devworkspace/"
OPERATOR_DIR="$OUT_DIR/operators/che-operator/"
CHECLUSTER_DIR="$OUT_DIR/checluster/"
WORKSPACE_DIR="$OUT_DIR/devworkspaces/"

# Variables for operator + checluster CR install namespaces
PLATFORM=""
DWO_OPERATOR_NS=""
DWO_CSV_NAME=""
OPERATOR_NS=""
OPERATOR_CSV_NAME=""
CHECLUSTER_NS=""
CHECLUSTER_NAME=""

# Variables related to operator installation
CHE_OPERATOR_NAME="Eclipse Che"
CHE_OPERATOR_DEPLOY="che-operator"
CHE_OPERATOR_LABEL_SELECTOR="app=che-operator"
CHE_OPERATOR_SERVICE_NAME="che-operator-service"
CHE_DEPLOYMENT_NAMES="che che-dashboard che-gateway devfile-registry plugin-registry"

# Variables related to the DevWorkspace Operator installation
DWO_OPERATOR_NAME="DevWorkspace Operator"
DWO_OPERATOR_DEPLOY="devworkspace-controller-manager"
DWO_OPERATOR_LABEL_SELECTOR="app.kubernetes.io/name=devworkspace-controller,app.kubernetes.io/part-of=devworkspace-operator"
DWO_OPERATOR_SERVICE_NAME="devworkspace-controller-manager-service"
DWO_OPERATOR_WEBHOOKS_DEPLOY="devworkspace-webhook-server"
DWO_OPERATOR_WEBHOOKS_LABEL_SELECTOR="app.kubernetes.io/name=devworkspace-webhook-server,app.kubernetes.io/part-of=devworkspace-operator"
DWO_OPERATOR_WEBHOOKS_SERVICE_NAME="devworkspace-webhookserver"
DWO_GLOBAL_DWOC_NAME="devworkspace-operator-config"

# Variables related to DevWorkspace debug information
WORKSPACE_NAME=""
WORKSPACE_NAMESPACE=""

USAGE="Usage: ./get-debug-info.sh [OPTIONS]

This script requires kubectl and jq.

Options:
    -d, --dest-dir <DIRECTORY>
        Output debug information into specific directory. Directory must not already
        exist. By default, files will be output to ./che-debug-<timestamp>
    --workspace-name <NAME>
        Gather debugging information on a specific workspace with provided name.
    --workspace-namespace <NAMESPACE>
        Gather debugging information on a specific workspace in provided namespace.
    -z, --zip
        Compress debug information to a zip file for sharing in a bug report.
    --help
        Print this message.
"

function print_usage() {
  echo -e "$USAGE"
}

function error() {
  echo "[ERROR] $1"
}

function warning() {
  echo "[WARN]  $1"
}

function info() {
  echo "[INFO]  $1"
}

function parse_arguments() {
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
      '-d'|'--dest-dir')
      OUT_DIR="$2";
      DWO_DIR="$OUT_DIR/operators/devworkspace/"
      OPERATOR_DIR="$OUT_DIR/operators/che-operator/"
      CHECLUSTER_DIR="$OUT_DIR/checluster/"
      WORKSPACE_DIR="$OUT_DIR/devworkspaces/"
      shift;;
      '-z'|'--zip')
      ZIP="true";;
      '--workspace-name')
      WORKSPACE_NAME="$2"; shift;;
      '--workspace-namespace')
      WORKSPACE_NAMESPACE="$2"; shift;;
      '--help')
      print_usage; exit 0;;
      *)
      echo -e "Unknown option $1 is specified. See usage:\n"
      print_usage; exit 1
    esac
    shift
  done
}

function preflight_checks() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Not logged in to any cluster. Please log in an re-run this script"
    exit 1
  fi
  if [ -d "$OUT_DIR" ]; then
    error "Directory $OUT_DIR already exists"
    exit 1
  fi
  mkdir -p "$OUT_DIR"
  if ! command -v jq > /dev/null; then
    error "Command-line tool jq is required"
    exit 1
  fi
  if [ -n "$WORKSPACE_NAME" ] && [ -z "$WORKSPACE_NAMESPACE" ]; then
    error "Argument '--workspace-namespace' must be provided when '--workspace-name' is used"
    exit 1
  fi
  if [ -z "$WORKSPACE_NAME" ] && [ -n "$WORKSPACE_NAMESPACE" ]; then
    error "Argument '--workspace-name' must be provided when '--workspace-namespace' is used"
    exit 1
  fi
}

function detect_install() {
  # Detect OpenShift or Kubernetes
  if kubectl api-resources | grep route.openshift.io -q; then
    PLATFORM="openshift"
  else
    PLATFORM="kubernetes"
  fi

  # Find operator install namespaces and CSVs (if present)
  if [ "$PLATFORM" = "openshift" ]; then
    # CSVs get copied to every namespace, so we can just check openshift-operators even if the operator is not installed there
    DWO_CSV_NAME=$(kubectl get csv -n openshift-operators -o json | jq -r --arg OPERATOR_NAME "$DWO_OPERATOR_NAME" '.items[] | select(.spec.displayName == $OPERATOR_NAME) | .metadata.name')
    DWO_OPERATOR_NS=$(kubectl get csv "$DWO_CSV_NAME" -o json | jq -r '
      if .status.reason == "InstallSucceeded"
      then
        .metadata.namespace
      else
        .metadata.labels."olm.copiedFrom"
      end
      ')
    OPERATOR_CSV_NAME=$(kubectl get csv -n openshift-operators -o json | jq -r --arg OPERATOR_NAME "$CHE_OPERATOR_NAME" '.items[] | select(.spec.displayName == $OPERATOR_NAME) | .metadata.name')
    OPERATOR_NS=$(kubectl get csv "$OPERATOR_CSV_NAME" -o json | jq -r '
      if .status.reason == "InstallSucceeded"
      then
        .metadata.namespace
      else
        .metadata.labels."olm.copiedFrom"
      end
      ')
  else
    DWO_OPERATOR_NS=$(kubectl get deploy --all-namespaces -l "$DWO_OPERATOR_LABEL_SELECTOR" -o jsonpath="{..metadata.namespace}")
    OPERATOR_NS=$(kubectl get deploy --all-namespaces -l "$CHE_OPERATOR_LABEL_SELECTOR" -o jsonpath="{..metadata.namespace}")
  fi

  # Find CheCluster to get install namespace
  local CHECLUSTERS NUM_CHECLUSTERS
  CHECLUSTERS=$(kubectl get checlusters --all-namespaces -o json)
  NUM_CHECLUSTERS=$(echo "$CHECLUSTERS" | jq '.items | length')
  if [ "$NUM_CHECLUSTERS" == "0" ]; then
    warning "No CheClusters found in cluster, cannot get CheCluster info"
  else
    if [ "$NUM_CHECLUSTERS" != "1" ]; then
      warning "Found $NUM_CHECLUSTERS in cluster, checking only the first"
    fi
    CHECLUSTER_NAME=$(echo "$CHECLUSTERS" | jq -r '.items[0].metadata.name')
    CHECLUSTER_NS=$(echo "$CHECLUSTERS" | jq -r '.items[0].metadata.namespace')
  fi
}

# Get logs for all containers in a pod. Files will be named '<deployment-name>.<container-name>.log'
# Expects parameters:
#   $1 - name of *deployment* that defines pod
#   $2 - namespace of deployment
#   $3 - output directory
function pod_logs() {
  local DEPLOY_NAME="$1"
  local NAMESPACE="$2"
  local OUTPUT_DIR="$3"
  for container in $(kubectl get deploy "$DEPLOY_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.template.spec.containers[].name'); do
    kubectl logs "deploy/$DEPLOY_NAME" -n "$NAMESPACE" -c "$container" > "$OUTPUT_DIR/$DEPLOY_NAME.$container.log"
  done
  for container in $(kubectl get deploy "$DEPLOY_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.template.spec.initContainers[]?.name'); do
    kubectl logs "deploy/$DEPLOY_NAME" -n "$NAMESPACE" -c "$container" > "$OUTPUT_DIR/$DEPLOY_NAME.init-$container.log"
  done
}

function gather_devworkspace_operator() {
  info "Getting information about DevWorkspace Operator installation"
  mkdir -p "$DWO_DIR"
  if [ "$PLATFORM" == "openshift" ]; then
    # Get CSV
    kubectl get csv "$DWO_CSV_NAME" -n "$DWO_OPERATOR_NS" -o json | jq -r '.spec.version' > "$DWO_DIR/version.txt"
    kubectl get csv "$DWO_CSV_NAME" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/csv.yaml"
  fi

  # Gather info about controller
  kubectl get deploy "$DWO_OPERATOR_DEPLOY" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/controller.deploy.yaml"
  kubectl get po -l "$DWO_OPERATOR_LABEL_SELECTOR" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/controller.pods.yaml"
  kubectl get svc "$DWO_OPERATOR_SERVICE_NAME" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/controller.svc.yaml"
  pod_logs "$DWO_OPERATOR_DEPLOY" "$DWO_OPERATOR_NS" "$DWO_DIR"

  # Gather info about webhooks server
  kubectl get deploy "$DWO_OPERATOR_WEBHOOKS_DEPLOY" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/webhook-server.deploy.yaml"
  kubectl get po -l "$DWO_OPERATOR_WEBHOOKS_LABEL_SELECTOR" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/webhook-server.pods.yaml"
  kubectl get svc "$DWO_OPERATOR_WEBHOOKS_SERVICE_NAME" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/webhook-server.svc.yaml"
  pod_logs "$DWO_OPERATOR_WEBHOOKS_DEPLOY" "$DWO_OPERATOR_NS" "$DWO_DIR"

  # Gather info about global DWO config, if present
  if kubectl get dwoc "$DWO_GLOBAL_DWOC_NAME" -n "$DWO_OPERATOR_NS" > /dev/null 2>&1; then
    kubectl get dwoc "$DWO_GLOBAL_DWOC_NAME" -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/operator-config.yaml"
  fi

  kubectl get events -n "$DWO_OPERATOR_NS" -o yaml > "$DWO_DIR/events.yaml" 2>/dev/null
  kubectl get events -n "$DWO_OPERATOR_NS" > "$DWO_DIR/events.txt" 2>/dev/null
}

function gather_che_operator() {
  info "Getting information about $CHE_OPERATOR_NAME installation"
  mkdir -p "$OPERATOR_DIR"
  if [ "$PLATFORM" == "openshift" ]; then
    # Get CSV
    kubectl get csv "$OPERATOR_CSV_NAME" -n "$OPERATOR_NS" -o json | jq -r '.spec.version' > "$OPERATOR_DIR/version.txt"
    kubectl get csv "$OPERATOR_CSV_NAME" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/csv.yaml"
  fi

  # Gather info about controller
  kubectl get deploy "$CHE_OPERATOR_DEPLOY" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.deploy.yaml"
  kubectl get po -l "$CHE_OPERATOR_LABEL_SELECTOR" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.pods.yaml"
  kubectl get svc "$CHE_OPERATOR_SERVICE_NAME" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.svc.yaml"
  pod_logs "$CHE_OPERATOR_DEPLOY" "$OPERATOR_NS" "$OPERATOR_DIR"
  kubectl get events -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/events.yaml" 2>/dev/null
  kubectl get events -n "$OPERATOR_NS" > "$OPERATOR_DIR/events.txt" 2>/dev/null
}

function gather_checluster() {
  info "Getting information about CheCluster and related deployments"
  mkdir -p "$CHECLUSTER_DIR"
  kubectl get checlusters "$CHECLUSTER_NAME" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/checluster.yaml"
  for deploy in $CHE_DEPLOYMENT_NAMES; do
    mkdir -p "$CHECLUSTER_DIR/$deploy/"
    kubectl get deploy "$deploy" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/$deploy/deployment.yaml"
    pod_logs "$deploy" "$CHECLUSTER_NS" "$CHECLUSTER_DIR/$deploy/"
    if [ "$deploy" == "che" ]; then
      kubectl get svc "$deploy-host" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/$deploy/service.yaml"
    else
      kubectl get svc "$deploy" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/$deploy/service.yaml"
    fi
  done
  if [ "$PLATFORM" = "openshift" ]; then
    kubectl get routes -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/route.yaml"
  else
    kubectl get ingresses -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/ingress.yaml"
  fi
  kubectl get dwoc -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/devworkspaceoperatorconfig.yaml"
  kubectl get events -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/events.yaml" 2>/dev/null
  kubectl get events -n "$CHECLUSTER_NS" > "$CHECLUSTER_DIR/events.txt" 2>/dev/null
}

function gather_workspace() {
  info "Getting information about DevWorkspace $WORKSPACE_NAME in namespace $WORKSPACE_NAMESPACE"
  mkdir -p "$WORKSPACE_DIR"
  local DW_ID
  DW_ID=$(kubectl get devworkspace "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" -o json | jq -r '.status.devworkspaceId')
  kubectl get devworkspaces "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/devworkspace.yaml"
  kubectl get svc -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/services.yaml"
  kubectl get deploy -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/deployments.yaml"
  kubectl get pods -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/pods.yaml"
  if [ "$PLATFORM" = "openshift" ]; then
    kubectl get routes -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/routes.yaml"
  else
    kubectl get ingresses -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/ingresses.yaml"
  fi
  kubectl get cm -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/workspace-configmaps.yaml"
  kubectl get cm -l "controller.devfile.io/mount-to-devworkspace" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/mounted-configmaps.yaml"
  kubectl get sa -l "controller.devfile.io/devworkspace_id=$DW_ID" -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/serviceaccounts.yaml"
  kubectl get pvc -n "$WORKSPACE_NAMESPACE" -o yaml> "$WORKSPACE_DIR/pvcs.yaml"
  kubectl get events -n "$WORKSPACE_NAMESPACE" -o yaml > "$WORKSPACE_DIR/events.yaml" 2>/dev/null
  kubectl get events -n "$WORKSPACE_NAMESPACE" > "$WORKSPACE_DIR/events.txt" 2>/dev/null
  pod_logs "$DW_ID" "$WORKSPACE_NAMESPACE" "$WORKSPACE_DIR"
}

function compress_results() {
  info "Compressing debug info to che_debug_info.zip"
  pushd "$(dirname "$OUT_DIR")" >/dev/null
  zip -q -r che_debug_info.zip "$(basename "$OUT_DIR")"
  popd >/dev/null
}

parse_arguments "$@"
preflight_checks

detect_install
cat <<EOF
Detected installation:
  * Che Operator installed in namespace $OPERATOR_NS
  * DevWorkspace Operator installed in namespace $DWO_OPERATOR_NS
  * Che installed in namespace $CHECLUSTER_NS

Results will be saved to $OUT_DIR
EOF

gather_devworkspace_operator

gather_che_operator

if [ "$CHECLUSTER_NAME" != "" ]; then
  gather_checluster
fi

if [ "$WORKSPACE_NAME" != "" ]; then
  gather_workspace
fi

if [ "$ZIP" == "true" ]; then
  compress_results
fi
