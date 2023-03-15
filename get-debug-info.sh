#!/bin/bash

set -e

# Output directories
SCRIPT_DIR=$(cd "$(dirname "$0")" || exit; pwd)
OUT_DIR="${SCRIPT_DIR}/che-debug-$(date -u +%y%m%d%H%M%S)/"
DWO_DIR="$OUT_DIR/operators/devworkspace/"
OPERATOR_DIR="$OUT_DIR/operators/che-operator/"
CHECLUSTER_DIR="$OUT_DIR/checluster/"
WORKSPACE_DIR="$OUT_DIR/devworkspaces/"

# Variables to distinguish between Eclipse Che and Dev Spaces installs on OpenShift or Kubernetes
OPERATOR_DIST=""      # che or devspaces
PLATFORM=""           # kubernetes or openshift

# Variables for operator + checluster CR install namespaces. Set in detect_install
DWO_OPERATOR_NS=""
DWO_CSV_NAME=""
OPERATOR_NS=""
OPERATOR_CSV_NAME=""
CHECLUSTER_NS=""
CHECLUSTER_NAME=""

# Variables related to operator installation. Set in detect_install
OPERATOR_NAME=""
OPERATOR_DEPLOY=""
OPERATOR_LABEL_SELECTOR=""
OPERATOR_SERVICE_NAME=""
DEPLOYMENT_NAMES=""

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
DEBUG_START="false"

function print_usage() {
cat <<EOF
This is a script used to gather information about a Eclipse Che or Red Hat
OpenShift Dev Spaces installation that is useful for diagnosing issues.

By default this script will gather the following information:
  * Any objects owned by the DevWorkspace or Eclipse Che/Dev Spaces operator in
    each operator's installed namespace
  * Any objects related to an existing Eclipse Che or Dev Spaces installation
    in the namespace of a CheCluster resource
The objects retrieved from the cluster are deployments, pods, services,
configmaps, services, routes/ingresses, events, and ClusterServiceVersions
(if present).

In addition, if the --workspace-name and --workspace-namespace options are
provided, this script will attempt to gather information about the specified
workspace.

In order to gather information about a workspace that fails to start, the
--debug-workspace-start option can be used. This will attempt to start the
workspace before gathering information.

This script requires kubectl and jq.

Usage: ./get-debug-info.sh [OPTIONS]

Options:
  --workspace-name <NAME>
      Gather debugging information on a specific workspace with provided name.
  --workspace-namespace <NAMESPACE>
      Gather debugging information on a specific workspace in provided namespace.
  --debug-workspace-start
      Gather debug information for a workspace that fails to start. This will
      patch the DevWorkspace object to attempt to start it before gathering data.
  --checluster-namespace <NAMESPACE>
      Use provided namespace to search for CheCluster. Optional: by defualt all
      namespaces are searched for CheClusters.
  -d, --dest-dir <DIRECTORY>
      Output debug information into specific directory. Directory must not
      already exist. By default, files will be output to ./che-debug-<timestamp>
  -z, --zip
      Compress debug information to a zip file for sharing in a bug report.
  --help
      Print this message.
EOF
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
      shift;;
      '-z'|'--zip')
      ZIP="true";;
      '--workspace-name')
      WORKSPACE_NAME="$2"; shift;;
      '--workspace-namespace')
      WORKSPACE_NAMESPACE="$2"; shift;;
      '--checluster-namespace')
      CHECLUSTER_NS="$2"; shift;;
      '--debug-workspace-start')
      DEBUG_START="true";;
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
  if [ "$DEBUG_START" == "true" ] && [ -z "$WORKSPACE_NAME" ]; then
    error "Arguments '--workspace-name' and '--workspace-namespace' must be provided with --debug-workspace-start"
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

  # Figure out if Eclipse Che or Dev Spaces is installed
  if [ "$PLATFORM" == "openshift" ]; then
    if kubectl get csv -n openshift-operators -o name | grep -q eclipse-che; then
      OPERATOR_DIST="che"
      OPERATOR_NAME="Eclipse Che"
      OPERATOR_DEPLOY="che-operator"
      OPERATOR_LABEL_SELECTOR="app=che-operator"
      OPERATOR_SERVICE_NAME="che-operator-service"
      DEPLOYMENT_NAMES="che che-dashboard che-gateway devfile-registry plugin-registry"
    elif kubectl get csv -n openshift-operators -o name | grep -q devspacesoperator; then
      OPERATOR_DIST="devspaces"
      OPERATOR_NAME="Red Hat OpenShift Dev Spaces"
      OPERATOR_DEPLOY="devspaces-operator"
      OPERATOR_LABEL_SELECTOR="app=devspaces-operator"
      OPERATOR_SERVICE_NAME="devspaces-operator-service"
      DEPLOYMENT_NAMES="devspaces devspaces-dashboard che-gateway devfile-registry plugin-registry"
    else
      error "Could not find operator installation"
      exit 1
    fi
  else
    # No Dev Spaces on Kubernetes
    OPERATOR_DIST="che"
    OPERATOR_NAME="Eclipse Che"
    OPERATOR_DEPLOY="che-operator"
    OPERATOR_LABEL_SELECTOR="app=che-operator"
    OPERATOR_SERVICE_NAME="che-operator-service"
    DEPLOYMENT_NAMES="che che-dashboard che-gateway devfile-registry plugin-registry"
  fi
  info "Detected $OPERATOR_NAME install in cluster"

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
    OPERATOR_CSV_NAME=$(kubectl get csv -n openshift-operators -o json | jq -r --arg OPERATOR_NAME "$OPERATOR_NAME" '.items[] | select(.spec.displayName == $OPERATOR_NAME) | .metadata.name')
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
    OPERATOR_NS=$(kubectl get deploy --all-namespaces -l "$OPERATOR_LABEL_SELECTOR" -o jsonpath="{..metadata.namespace}")
  fi

  # Find CheCluster to get install namespace
  local CHECLUSTERS NUM_CHECLUSTERS
  if [ -z "$CHECLUSTER_NS" ]; then
    # No namespace specified -- search whole cluster for CheClusters. This requires higher permissions
    CHECLUSTERS=$(kubectl get checlusters --all-namespaces -o json)
    NUM_CHECLUSTERS=$(echo "$CHECLUSTERS" | jq '.items | length')
  else
    CHECLUSTERS=$(kubectl get checlusters -n "$CHECLUSTER_NS" -o json)
    NUM_CHECLUSTERS=$(echo "$CHECLUSTERS" | jq '.items | length')
  fi
  if [ "$NUM_CHECLUSTERS" == "0" ]; then
    warning "No CheClusters found in cluster, cannot get CheCluster info"
  else
    if [ "$NUM_CHECLUSTERS" != "1" ]; then
      warning "Found $NUM_CHECLUSTERS in cluster, checking only the first"
    fi
    CHECLUSTER_NS=$(echo "$CHECLUSTERS" | jq -r '.items[0].metadata.namespace')
    CHECLUSTER_NAME=$(echo "$CHECLUSTERS" | jq -r '.items[0].metadata.name')
  fi
}

# Set the controller.devfile.io/debug-start='true' annotation on the workspace and start it, waiting for it to either
# enter a Running or Failing phase before continuing. Waiting on phase has a 6 minute timeout
function set_debug_on_workspace() {
  info "Starting DevWorkspace $WORKSPACE_NAME in namespace $WORKSPACE_NAMESPACE with debug enabled"
  kubectl annotate --overwrite devworkspace "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" controller.devfile.io/debug-start='true' >/dev/null
  kubectl patch devworkspace "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" --type merge -p '{"spec": {"started": true}}' >/dev/null
  info "Waiting for DevWorkspace to enter 'Running' or 'Failing' state (timeout is 3 minutes)."
  local WORKSPACE_STATE
  # 3 minute timeout
  for _ in {1..60}; do
    WORKSPACE_STATE=$(kubectl get devworkspace "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" -o json | jq -r '.status.phase')
    if [ "$WORKSPACE_STATE" == "Running" ] || [ "$WORKSPACE_STATE" == "Failing" ]; then break; fi
    echo -n "."
    sleep 3
  done
  echo ""
  case "$WORKSPACE_STATE" in
  "Running"|"Failing")
  info "Workspace phase is $WORKSPACE_STATE. Continuing.";;
  *)
  warning "Waiting for DevWorkspace timed out. Current DevWorkspace phase is $WORKSPACE_STATE";;
  esac
}

# Undo changes from set_debug_on_workspace, removing the controller.devfile.io/debug-start annotation
function reset_workspace_changes() {
  kubectl annotate devworkspace "$WORKSPACE_NAME" -n "$WORKSPACE_NAMESPACE" controller.devfile.io/debug-start- >/dev/null 2>&1
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
    # Pod may not be running, so don't fail script here if command fails.
    kubectl logs "deploy/$DEPLOY_NAME" -n "$NAMESPACE" -c "$container" > "$OUTPUT_DIR/$DEPLOY_NAME.$container.log" 2>/dev/null || true
  done
  for container in $(kubectl get deploy "$DEPLOY_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.template.spec.initContainers[]?.name'); do
    kubectl logs "deploy/$DEPLOY_NAME" -n "$NAMESPACE" -c "$container" > "$OUTPUT_DIR/$DEPLOY_NAME.init-$container.log" 2>/dev/null || true
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
  info "Getting information about $OPERATOR_NAME installation"
  mkdir -p "$OPERATOR_DIR"
  if [ "$PLATFORM" == "openshift" ]; then
    # Get CSV
    kubectl get csv "$OPERATOR_CSV_NAME" -n "$OPERATOR_NS" -o json | jq -r '.spec.version' > "$OPERATOR_DIR/version.txt"
    kubectl get csv "$OPERATOR_CSV_NAME" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/csv.yaml"
  fi

  # Gather info about controller
  kubectl get deploy "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.deploy.yaml"
  kubectl get po -l "$OPERATOR_LABEL_SELECTOR" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.pods.yaml"
  kubectl get svc "$OPERATOR_SERVICE_NAME" -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/controller.svc.yaml"
  pod_logs "$OPERATOR_DEPLOY" "$OPERATOR_NS" "$OPERATOR_DIR"
  kubectl get events -n "$OPERATOR_NS" -o yaml > "$OPERATOR_DIR/events.yaml" 2>/dev/null
  kubectl get events -n "$OPERATOR_NS" > "$OPERATOR_DIR/events.txt" 2>/dev/null
}

function gather_checluster() {
  info "Getting information about CheCluster and related deployments"
  mkdir -p "$CHECLUSTER_DIR"
  kubectl get checlusters "$CHECLUSTER_NAME" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/checluster.yaml"
  for deploy in $DEPLOYMENT_NAMES; do
    mkdir -p "$CHECLUSTER_DIR/$deploy/"
    kubectl get deploy "$deploy" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/$deploy/deployment.yaml"
    pod_logs "$deploy" "$CHECLUSTER_NS" "$CHECLUSTER_DIR/$deploy/"
    if [ "$deploy" == "che" ] || [ "$deploy" == "devspaces" ]; then
      # Even if the install is Dev Spaces, the service is named che-host
      kubectl get svc "che-host" -n "$CHECLUSTER_NS" -o yaml > "$CHECLUSTER_DIR/$deploy/service.yaml"
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
info "Detected installation:"
info "  * $OPERATOR_NAME Operator installed in namespace $OPERATOR_NS"
info "  * DevWorkspace Operator installed in namespace $DWO_OPERATOR_NS"
if [ "$CHECLUSTER_NAME" != "" ]; then
  info "  * $OPERATOR_NAME installed in namespace $CHECLUSTER_NS"
fi
info ""
info "Results will be saved to $OUT_DIR"

DWO_DIR="$OUT_DIR/operators/devworkspace-operator/"
OPERATOR_DIR="$OUT_DIR/operators/$OPERATOR_DIST-operator/"
CHECLUSTER_DIR="$OUT_DIR/checluster/"
WORKSPACE_DIR="$OUT_DIR/devworkspaces/"

if [ $DEBUG_START == "true" ]; then
  set_debug_on_workspace
  trap reset_workspace_changes TERM INT HUP ERR
fi

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

if [ $DEBUG_START == "true" ]; then
  reset_workspace_changes
fi
